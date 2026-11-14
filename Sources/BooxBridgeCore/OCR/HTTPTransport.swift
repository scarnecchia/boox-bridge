// pattern: Imperative Shell
// HTTP transport seam. URLSessionTransport never forwards credentials
// cross-origin: redirects are validated by EndpointPolicy and cancelled
// otherwise. Cancelling the calling task cancels the in-flight
// URLSessionTask and surfaces CancellationError, never a fake transport
// failure. Delegate work lives at SESSION level: a delegate attached to a
// data task after creation is never consulted on Linux FoundationNetworking,
// which left every request here unable to complete at all. Tests stub
// HTTPTransporting to inspect exact wire bytes.

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Equatable, Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data = Data()) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public enum HTTPFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case rejectedEndpoint(reason: String)
    case blockedRedirect(to: String)
    case transportError(String)

    public var description: String {
        switch self {
        case .rejectedEndpoint(let r): return "endpoint rejected: \(r)"
        case .blockedRedirect(let to): return "redirect to \(to) would leak credentials; blocked"
        case .transportError(let d): return "network failure: \(d)"
        }
    }
}

public protocol HTTPTransporting: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransporting {
    private let session: URLSession
    private let policies: SessionPolicies

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.init(configuration: config)
    }

    /// Seam for tests that need custom timeouts or protocol stubbing; the
    /// redirect and credential guards below are installed regardless.
    public init(configuration: URLSessionConfiguration) {
        let policies = SessionPolicies()
        // No global ATS weakening anywhere; HTTPS-only is enforced by policy.
        self.session = URLSession(configuration: configuration, delegate: policies, delegateQueue: nil)
        self.policies = policies
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch EndpointPolicy.validate(url: request.url) {
        case .rejected(let reason):
            throw HTTPFailure.rejectedEndpoint(reason: reason)
        case .allowed:
            break
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let task = session.dataTask(with: urlRequest)
        let identifier = task.taskIdentifier
        // Same-origin redirects re-attach OUR credentials; cross-origin
        // redirects are cancelled by the session policies below. Without
        // this, the server-built redirect request would either strip or
        // replay headers we never set.
        policies.stage(
            task: task,
            originalURL: request.url,
            authorizationHeader: request.headers["Authorization"],
            apiKeyHeader: request.headers["x-api-key"]
        )

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    policies.bind(continuation: continuation, to: identifier)
                    task.resume()
                }
            } onCancel: {
                // Bridge task cancellation to the in-flight request; see
                // SessionPolicies.cancel for why the caller is also unblocked
                // immediately instead of waiting for URLSession.
                policies.cancel(identifier)
            }
        } catch is CancellationError {
            // Cancellation must surface as cancellation, not as a spurious
            // transport failure: callers distinguish "we stopped it" from
            // "the network broke" when deciding what to record or retry.
            throw CancellationError()
        } catch let error as NSError {
            throw HTTPFailure.transportError(error.localizedDescription)
        }
    }

    /// Session-level policy delegate. One transport owns one session, so
    /// this type is the redirect guard, credential reattacher, response
    /// buffer, and completion dispatcher for every task it sees, keyed by
    /// task identifier.
    private final class SessionPolicies: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private final class RequestContext: @unchecked Sendable {
            let task: URLSessionTask
            let originalURL: URL
            let authorizationHeader: String?
            let apiKeyHeader: String?
            let box = ContinuationBox()
            /// True once a continuation was bound; only then may pruning
            /// drop the context, so a cancelled-before-bind request can
            /// never strand its continuation.
            var bound = false
            var data = Data()

            init(task: URLSessionTask, originalURL: URL, authorizationHeader: String?, apiKeyHeader: String?) {
                self.task = task
                self.originalURL = originalURL
                self.authorizationHeader = authorizationHeader
                self.apiKeyHeader = apiKeyHeader
            }
        }

        private let lock = NSLock()
        private var contexts: [Int: RequestContext] = [:]

        /// Register a task's policy context before its request starts.
        func stage(task: URLSessionTask, originalURL: URL, authorizationHeader: String?, apiKeyHeader: String?) {
            lock.lock()
            // Drop contexts that resolved without a completion callback
            // (cancelled requests on platforms whose URLSession never
            // reports them); unbound ones must stay reachable for bind().
            contexts = contexts.filter { $0.value.bound && $0.value.box.isFinished }
            contexts[task.taskIdentifier] = RequestContext(
                task: task, originalURL: originalURL,
                authorizationHeader: authorizationHeader, apiKeyHeader: apiKeyHeader
            )
            lock.unlock()
        }

        func bind(continuation: CheckedContinuation<HTTPResponse, Error>, to identifier: Int) {
            lock.lock()
            let context = contexts[identifier]
            context?.bound = true
            lock.unlock()
            // The context survives until a completion or a later prune, so
            // the box is always reachable here and the continuation can
            // never strand.
            context?.box.store(continuation)
        }

        /// Cancel the in-flight request and unblock the caller at once.
        /// Some platforms' URLSession (Linux FoundationNetworking) never
        /// reports a completion for a cancelled task, so waiting for the
        /// session would hang the await until the resource timeout; the
        /// resume-once box carries the cancellation itself and absorbs any
        /// late completion the session does deliver.
        func cancel(_ identifier: Int) {
            lock.lock()
            let task = contexts[identifier]?.task
            let box = contexts[identifier]?.box
            lock.unlock()
            task?.cancel()
            box?.finish(.failure(CancellationError()))
        }

        private func context(for task: URLSessionTask) -> RequestContext? {
            lock.lock()
            defer { lock.unlock() }
            return contexts[task.taskIdentifier]
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        willCacheResponse cachedResponse: CachedURLResponse,
                        completionHandler: @escaping (CachedURLResponse?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            // Hard cap: a runaway response must not buffer unbounded bytes.
            _ = context(for: dataTask).map { context in
                if context.data.count + data.count <= ProviderWire.maxResponseBytes + 64 * 1024 {
                    context.data.append(data)
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let context = context(for: task),
                  let url = request.url,
                  EndpointPolicy.redirectAllowed(from: context.originalURL, to: url) else {
                completionHandler(nil)
                return
            }
            // Strip any headers the server may try to inject; our key stays
            // in the headers WE set on the redirected request.
            var cleaned = request
            cleaned.setValue(context.authorizationHeader, forHTTPHeaderField: "Authorization")
            cleaned.setValue(context.apiKeyHeader, forHTTPHeaderField: "x-api-key")
            completionHandler(cleaned)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let context = contexts.removeValue(forKey: task.taskIdentifier)
            let buffered = context?.data ?? Data()
            lock.unlock()

            guard let context else {
                // Already resolved by cancellation; nothing to report.
                return
            }
            if let error {
                if Self.isCancellation(error) {
                    // Task cancellation landed here: report cancellation, not
                    // a network failure, so callers can tell the two apart.
                    context.box.finish(.failure(CancellationError()))
                } else {
                    context.box.finish(.failure(HTTPFailure.transportError(error.localizedDescription)))
                }
                return
            }
            guard let http = task.response as? HTTPURLResponse else {
                context.box.finish(.failure(HTTPFailure.transportError("no HTTP response")))
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String {
                    headers[k.lowercased()] = v
                }
            }
            context.box.finish(.success(HTTPResponse(status: http.statusCode, headers: headers, body: buffered)))
        }

        private static func isCancellation(_ error: Error) -> Bool {
            let nsError = error as NSError
            return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        }
    }

    /// Resume-once guard for the continuation. Finish may arrive before the
    /// continuation is bound (cancellation racing the operation body); the
    /// result is stashed and delivered at bind time instead. Whatever the
    /// interleaving, the continuation resumes exactly once.
    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<HTTPResponse, Error>?
        private var stashed: Result<HTTPResponse, Error>?

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation == nil && stashed != nil
        }

        func store(_ continuation: CheckedContinuation<HTTPResponse, Error>) {
            lock.lock()
            if let stashed {
                lock.unlock()
                continuation.resume(with: stashed)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ result: Result<HTTPResponse, Error>) {
            lock.lock()
            if let continuation = self.continuation {
                self.continuation = nil
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            if stashed == nil {
                stashed = result
            }
            lock.unlock()
        }
    }
}
