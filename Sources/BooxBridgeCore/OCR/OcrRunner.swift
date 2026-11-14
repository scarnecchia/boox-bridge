// pattern: Imperative Shell
// Durable OCR runner. Single-concurrency, bounded retries with an injected
// clock, revision checks before committing late responses, and credential
// redaction on every error path. Secrets never appear in errors, logs, or
// the catalog.

import Foundation

public enum OcrOutcome: Equatable, Sendable {
    case succeeded(text: String)
    /// retryable marks transient failures (network, 429/5xx) that the drain
    /// loop may requeue with backoff; permanent failures are terminal.
    case failed(jobID: Int64, reason: String, retryable: Bool)
    case staleDiscarded(revisionID: Int64)
}

public enum OcrRunError: Error, Equatable, Sendable, CustomStringConvertible {
    case staleResult(revisionID: Int64)
    case keyMissing(profileID: String)
    case endpointRejected(reason: String)
    case retryable(delay: TimeInterval, reason: String)
    case permanent(reason: String)
    case cancelled

    public var description: String {
        switch self {
        case .staleResult(let r): return "result arrived for revision \(r), which is no longer current; discarded"
        case .keyMissing(let p): return CredentialError.missingKey(profileID: p).description
        case .endpointRejected(let r): return r
        case .retryable(let d, let r): return "transient failure (\(r)); retry in \(Int(d))s"
        case .permanent(let r): return r
        case .cancelled: return "OCR cancelled"
        }
    }
}

public struct OcrRunnerLimits: Sendable {
    public var retry = RetryLimits()
    public var maxImageDimensionPoints: CGFloat = 2000

    public init() {}
}

public actor OcrRunner {
    private let catalog: CatalogStore
    private let transport: HTTPTransporting
    private let credentials: CredentialStoring
    private let renderer: PageRendering
    private let clock: WallClock
    private let limits: OcrRunnerLimits

    public init(
        catalog: CatalogStore,
        transport: HTTPTransporting,
        credentials: CredentialStoring,
        renderer: PageRendering,
        clock: WallClock = SystemClock(),
        limits: OcrRunnerLimits = OcrRunnerLimits()
    ) {
        self.catalog = catalog
        self.transport = transport
        self.credentials = credentials
        self.renderer = renderer
        self.clock = clock
        self.limits = limits
    }

    /// Execute one job end-to-end. The caller (drain/manual retry) owns
    /// state transitions; this method is the network+decode+commit core.
    public func execute(
        job: OcrJob,
        profile: ProviderProfile,
        prompt: String = PromptVersion.text
    ) async -> OcrOutcome {
        do {
            try checkRevisionFresh(job: job)

            guard let key = try credentials.secret(forProfileID: profile.id), !key.isEmpty else {
                throw OcrRunError.keyMissing(profileID: profile.id)
            }

            guard let revisionHash = try catalog.revisionContentSHA256(revisionID: job.revisionID) else {
                throw OcrRunError.staleResult(revisionID: job.revisionID)
            }
            let imageData = try renderer.pngData(
                revisionSHA256: revisionHash,
                pageIndex: job.pageIndex,
                maxDimensionPoints: limits.maxImageDimensionPoints
            )

            let request = try ProviderWire.makeRequest(
                profile: profile, apiKey: key, prompt: prompt,
                imagePNGData: imageData
            )

            let response = try await send(request)
            let text = try ProviderWire.decodeTranscription(kind: profile.kind, body: response.body)

            // Late-response guard: commit only if this revision is still
            // the document's current revision.
            try checkRevisionFresh(job: job)
            try catalog.recordTranscription(
                revisionID: job.revisionID, pageIndex: job.pageIndex, rawText: text, at: clock.now()
            )
            try catalog.updateJob(
                id: job.id, state: .succeeded, attempts: job.attempts + 1,
                lastError: nil, at: clock.now()
            )
            return .succeeded(text: text)
        } catch let error as OcrRunError {
            if case .staleResult = error {
                try? catalog.updateJob(
                    id: job.id, state: .failed, attempts: job.attempts + 1,
                    lastError: error.description, at: clock.now()
                )
                return .staleDiscarded(revisionID: job.revisionID)
            }
            if case .retryable = error {
                return .failed(jobID: job.id, reason: error.description, retryable: true)
            }
            return .failed(jobID: job.id, reason: error.description, retryable: false)
        } catch {
            return .failed(jobID: job.id, reason: String(describing: error), retryable: false)
        }
    }

    /// Drain the durable queue at concurrency 1. Cancelling the enclosing
    /// task stops scheduling new pages and aborts in-flight work where the
    /// transport allows; a request already sent may still have been billed,
    /// which the UI must disclose.
    public func drain(
        profileResolver: @Sendable (_ profileID: String) -> ProviderProfile?
    ) async {
        while let job = try? catalog.nextQueuedJob() {
            guard let profile = profileResolver(job.profileID) else {
                try? catalog.updateJob(
                    id: job.id, state: .failed, attempts: job.attempts + 1,
                    lastError: "profile \(job.profileID) is no longer configured", at: clock.now()
                )
                continue
            }
            try? catalog.updateJob(
                id: job.id, state: .running, attempts: job.attempts, lastError: nil, at: clock.now()
            )
            let outcome = await execute(job: job, profile: profile)
            switch outcome {
            case .succeeded:
                continue
            case .staleDiscarded:
                continue
            case .failed(let jobID, let reason, let retryable):
                let nextAttempt = job.attempts + 1
                if retryable, nextAttempt < limits.retry.maxAttempts {
                    let requeueDelay = RetryPolicy.backoff(attempt: job.attempts, limits: limits.retry)
                    try? catalog.updateJob(
                        id: jobID, state: .queued, attempts: nextAttempt,
                        lastError: reason, at: clock.now()
                    )
                    try? await clock.sleep(for: requeueDelay)
                } else {
                    try? catalog.updateJob(
                        id: jobID, state: .failed, attempts: nextAttempt,
                        lastError: reason.isEmpty ? "failed" : reason, at: clock.now()
                    )
                }
            }
        }
    }

    /// The synthetic capability probe: sends ONLY the 1x1 synthetic image,
    /// never a user page. Records the result for the exact profile+model.
    public func probeImageCapability(profile: ProviderProfile) async -> ImageCapability {
        guard let key = try? credentials.secret(forProfileID: profile.id), !key.isEmpty else {
            return .rejected(reason: CredentialError.missingKey(profileID: profile.id).description)
        }
        do {
            let request = try ProviderWire.makeRequest(
                profile: profile, apiKey: key, prompt: ProviderWire.syntheticTestPrompt,
                imagePNGData: SyntheticProbeImage.png
            )
            let response = try await send(request)
            switch response.status {
            case 200:
                _ = try ProviderWire.decodeTranscription(kind: profile.kind, body: response.body)
                return .verified
            case 401, 403:
                return .rejected(reason: "authentication rejected — check the API key")
            case 400, 404, 415, 422:
                return .rejected(reason: "model rejected image input (status \(response.status)) — choose a vision-capable model")
            default:
                return .rejected(reason: "unexpected status \(response.status)")
            }
        } catch let error as HTTPFailure {
            if case .rejectedEndpoint(let reason) = error {
                return .rejected(reason: reason)
            }
            return .rejected(reason: "network failure: \(error.localizedDescription)")
        } catch {
            return .rejected(reason: String(describing: error))
        }
    }

    // MARK: - Internals

    private func send(_ request: WireRequest) async throws -> HTTPResponse {
        // Defense in depth: policy runs here AND inside URLSessionTransport,
        // so scripted/test transports cannot bypass it.
        switch EndpointPolicy.validate(url: request.url) {
        case .rejected(let reason):
            throw OcrRunError.endpointRejected(reason: reason)
        case .allowed:
            break
        }
        do {
            let response = try await transport.send(HTTPRequest(
                url: request.url, method: request.method,
                headers: request.headers, body: request.body
            ))
            guard (200..<300).contains(response.status) else {
                let decision = RetryPolicy.decide(
                    status: response.status,
                    retryAfterHeader: response.headers["retry-after"],
                    attempt: 0,
                    limits: limits.retry
                )
                switch decision {
                case .retryAfter(let delay, let reason):
                    throw OcrRunError.retryable(delay: delay, reason: reason)
                case .fail(let reason):
                    throw OcrRunError.permanent(reason: reason)
                }
            }
            return response
        } catch let error as HTTPFailure {
            if case .rejectedEndpoint(let reason) = error {
                throw OcrRunError.endpointRejected(reason: reason)
            }
            // Network-level failures are retryable with bounded backoff.
            throw OcrRunError.retryable(
                delay: RetryPolicy.backoff(attempt: 0, limits: limits.retry),
                reason: error.localizedDescription
            )
        }
    }

    private func checkRevisionFresh(job: OcrJob) throws {
        guard let documentID = try catalog.documentID(revisionID: job.revisionID),
              let current = try catalog.currentRevisionID(documentID: documentID),
              current == job.revisionID else {
            throw OcrRunError.staleResult(revisionID: job.revisionID)
        }
    }
}
