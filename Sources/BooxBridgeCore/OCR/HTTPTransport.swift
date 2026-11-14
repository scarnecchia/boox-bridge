// pattern: Imperative Shell
// HTTP transport seam. URLSessionTransport never forwards credentials
// cross-origin: redirects are validated by EndpointPolicy and cancelled
// otherwise. Tests stub HTTPTransporting to inspect exact wire bytes.

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

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        // No global ATS weakening anywhere; HTTPS-only is enforced by policy.
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch EndpointPolicy.validate(url: request.url) {
        case .rejected(let reason):
            throw HTTPFailure.rejectedEndpoint(reason: reason)
        case .allowed:
            break
        }

        let guard_ = RedirectGuardDelegate(originalURL: request.url)
        // Same-origin redirects re-attach OUR credentials; cross-origin
        // redirects are cancelled below. Without this, the server-built
        // redirect request would either strip or replay headers we never set.
        guard_.authorizationHeader = request.headers["Authorization"]
        guard_.apiKeyHeader = request.headers["x-api-key"]

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let task = session.dataTask(with: urlRequest)

        do {
            return try await withCheckedThrowingContinuation { continuation in
                let box = ContinuationBox(continuation)
                // URLSession retains the task delegate until completion, so
                // no external retention is needed.
                task.delegate = ComposedTask(delegate: guard_, box: box)
                task.resume()
            }
        } catch let error as NSError {
            throw HTTPFailure.transportError(error.localizedDescription)
        }
    }

    private final class ContinuationBox: @unchecked Sendable {
        enum State { case pending, finished }
        private let lock = NSLock()
        private var state: State = .pending
        private let continuation: CheckedContinuation<HTTPResponse, Error>

        init(_ continuation: CheckedContinuation<HTTPResponse, Error>) {
            self.continuation = continuation
        }

        func finish(_ result: Result<HTTPResponse, Error>) {
            lock.lock()
            let already = state == .finished
            state = .finished
            lock.unlock()
            guard !already else { return }
            continuation.resume(with: result)
        }
    }

    private final class ComposedTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let delegate: RedirectGuardDelegate
        let box: ContinuationBox
        private var data = Data()

        init(delegate: RedirectGuardDelegate, box: ContinuationBox) {
            self.delegate = delegate
            self.box = box
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        willCacheResponse cachedResponse: CachedURLResponse,
                        completionHandler: @escaping (CachedURLResponse?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            // Hard cap: a runaway response must not buffer unbounded bytes.
            if self.data.count + data.count <= ProviderWire.maxResponseBytes + 64 * 1024 {
                self.data.append(data)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url,
                  EndpointPolicy.redirectAllowed(from: delegate.originalURL, to: url) else {
                completionHandler(nil)
                return
            }
            // Strip any headers the server may try to inject; our key stays
            // in the headers WE set on the redirected request.
            var cleaned = request
            cleaned.setValue(delegate.authorizationHeader, forHTTPHeaderField: "Authorization")
            cleaned.setValue(delegate.apiKeyHeader, forHTTPHeaderField: "x-api-key")
            completionHandler(cleaned)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                box.finish(.failure(HTTPFailure.transportError(error.localizedDescription)))
                return
            }
            guard let http = task.response as? HTTPURLResponse else {
                box.finish(.failure(HTTPFailure.transportError("no HTTP response")))
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String {
                    headers[k.lowercased()] = v
                }
            }
            box.finish(.success(HTTPResponse(status: http.statusCode, headers: headers, body: data)))
        }

    }

    private final class RedirectGuardDelegate: @unchecked Sendable {
        let originalURL: URL
        var authorizationHeader: String?
        var apiKeyHeader: String?

        init(originalURL: URL) {
            self.originalURL = originalURL
        }
    }
}
