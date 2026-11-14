import Foundation
import Testing
@testable import BooxBridgeCore

final class ScriptedTransport: HTTPTransporting, @unchecked Sendable {
    struct Recorded: Equatable {
        let url: String
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private var responses: [HTTPResponse] = []
    private var failures: [HTTPFailure] = []
    private(set) var recorded: [Recorded] = []

    func enqueue(_ response: HTTPResponse) {
        lock.lock(); defer { lock.unlock() }
        responses.append(response)
    }

    func enqueueFailure(_ failure: HTTPFailure) {
        lock.lock(); defer { lock.unlock() }
        failures.append(failure)
    }

    /// Runs at the start of each send, under the lock — a test can rotate
    /// the credential store while a request is in flight (mid-drain rotation).
    var onSend: (() -> Void)?

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try nextResponse(for: request)
    }

    private func nextResponse(for request: HTTPRequest) throws -> HTTPResponse {
        lock.lock(); defer { lock.unlock() }
        onSend?()
        recorded.append(Recorded(url: request.url.absoluteString, headers: request.headers, body: request.body))
        if !failures.isEmpty {
            throw failures.removeFirst()
        }
        guard !responses.isEmpty else {
            return HTTPResponse(status: 200, body: Data(#"{"output":[{"content":[{"type":"output_text","text":"default"}]}]}"#.utf8))
        }
        return responses.removeFirst()
    }
}

struct FixedRenderer: PageRendering {
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
    func pngData(revisionSHA256: String, pageIndex: Int, maxDimensionPoints: CGFloat) throws -> Data { png }
}

@Suite struct OcrQueueTests {
    func makeFixture(transport: ScriptedTransport, directory: URL) throws -> (CatalogStore, OcrRunner, InMemoryCredentialStore) {
        let catalog = try CatalogStore.open(atPath: directory.appendingPathComponent("c.sqlite").path)
        let credentials = InMemoryCredentialStore()
        let runner = OcrRunner(
            catalog: catalog, transport: transport,
            renderer: FixedRenderer(), clock: ManualClock()
        )
        return (catalog, runner, credentials)
    }

    /// The drain-time pair a resolver hands the runner: profile and key as
    /// one unit captured before the drain starts (see DrainCredential).
    func bound(_ profile: ProviderProfile, key: String = "k-1") -> DrainCredential {
        DrainCredential(profile: profile, apiKey: key)
    }

    func seedDocument(catalog: CatalogStore, pages: Int = 1) throws -> (Int64, Int64) {
        let outcome = try catalog.commitImport(
            key: DocumentKey(serial: "s", rootID: "r", relativePath: "note-\(UUID().uuidString).pdf"),
            kind: .pdf, contentSHA256: UUID().uuidString, sizeBytes: 10, pageCount: pages,
            remoteMtime: 1, remoteSize: 10, at: Date()
        )
        guard case .newDocument(let documentID, let revisionID) = outcome else {
            fatalError("seed failed")
        }
        return (documentID, revisionID)
    }


    @Test func queuePersistsAcrossReopenAndDeduplicates() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let (catalog, runner, credentials) = try makeFixture(transport: transport, directory: dir)
            try credentials.saveSecret("k-1", forProfileID: "p1")
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAI,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "m")
            let (_, revisionID) = try seedDocument(catalog: catalog)

            let firstJob = try catalog.enqueueJob(
                revisionID: revisionID, pageIndex: 0, profileID: "p1",
                modelID: "m", promptVersion: PromptVersion.current, at: Date()
            )
            #expect(firstJob != nil)
            #expect(try catalog.enqueueJob(
                revisionID: revisionID, pageIndex: 0, profileID: "p1",
                modelID: "m", promptVersion: PromptVersion.current, at: Date()
            ) == nil)

            transport.enqueue(HTTPResponse(status: 200, body: Data(#"{"output":[{"content":[{"type":"output_text","text":"page text"}]}]}"#.utf8)))
            await runner.drain(profileResolver: { $0 == "p1" ? bound(profile) : nil })

            let pages = try catalog.pages(revisionID: revisionID)
            #expect(pages[0].rawTranscription == "page text")
            #expect(pages[0].effectiveText == "page text")
            #expect(try catalog.search(matching: "page text").count == 1)
            let job = try catalog.job(id: firstJob!)!
            #expect(job.state == .succeeded)

            let reopened = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            #expect(try reopened.activeJobs().isEmpty)
            #expect(try reopened.pages(revisionID: revisionID)[0].effectiveText == "page text")
        }
    }

    @Test func userEditsSurviveReprocessing() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let (catalog, runner, credentials) = try makeFixture(transport: transport, directory: dir)
            try credentials.saveSecret("k-1", forProfileID: "p1")
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAI,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "m")
            let (_, revisionID) = try seedDocument(catalog: catalog)

            transport.enqueue(HTTPResponse(status: 200, body: Data(#"{"output":[{"content":[{"type":"output_text","text":"raw one"}]}]}"#.utf8)))
            _ = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p1",
                                       modelID: "m", promptVersion: 1, at: Date())
            await runner.drain(profileResolver: { _ in bound(profile) })

            let pages = try catalog.pages(revisionID: revisionID)
            try catalog.updateEffectiveText(pageID: pages[0].id, text: "my edited version", at: Date())

            transport.enqueue(HTTPResponse(status: 200, body: Data(#"{"output":[{"content":[{"type":"output_text","text":"raw two"}]}]}"#.utf8)))
            _ = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p1",
                                       modelID: "m2", promptVersion: 1, at: Date())
            await runner.drain(profileResolver: { _ in bound(profile) })

            let after = try catalog.pages(revisionID: revisionID)[0]
            #expect(after.rawTranscription == "raw two")
            #expect(after.effectiveText == "my edited version")
            #expect(after.lastEditedAt != nil)
        }
    }

    /// Consent fidelity: a queued job was approved under the (profile,
    /// model, prompt) tuple persisted on its row. Editing the provider's
    /// model while the queue is paused must not silently retarget queued
    /// pages: the executed request must carry the job's STORED model, even
    /// though the profile object handed to the drain names a different one.
    /// The endpoint and key are the drain-time pair the resolver supplies —
    /// here the edited profile with its key — so both travel as one unit.
    @Test func drainedJobExecutesStoredModelAgainstDrainTimePair() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let (catalog, runner, credentials) = try makeFixture(transport: transport, directory: dir)
            try credentials.saveSecret("k-1", forProfileID: "p1")
            let (_, revisionID) = try seedDocument(catalog: catalog)
            _ = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p1",
                                       modelID: "m-consented", promptVersion: PromptVersion.current, at: Date())

            // Queue paused: the user edits the provider to a different model
            // AND endpoint before resuming. (Immutable: Swift 6 forbids
            // capturing a var in the @Sendable resolver closure.)
            let edited = ProviderProfile(id: "p1", displayName: "P", kind: .openAI,
                                         baseURL: URL(string: "https://api.example.com/edited")!, modelID: "m-current")

            transport.enqueue(HTTPResponse(status: 200, body: Data(#"{"output":[{"content":[{"type":"output_text","text":"page text"}]}]}"#.utf8)))
            await runner.drain(profileResolver: { _ in bound(edited) })

            #expect(transport.recorded.count == 1)
            let wire = try #require(transport.recorded.first)
            let body = try #require(JSONSerialization.jsonObject(with: wire.body) as? [String: Any])
            #expect(body["model"] as? String == "m-consented")
            // Prompt identity also comes from the job row (its stored
            // version resolves to the current prompt text).
            let input = try #require(body["input"] as? [[String: Any]])
            let parts = try #require(input.first?["content"] as? [[String: Any]])
            #expect(parts.first?["text"] as? String == PromptVersion.text)
            // Endpoint and key are the drain-time pair from the resolver —
            // asserted here so both halves of the contract are pinned.
            #expect(wire.url.hasSuffix("/edited/responses"))
            #expect(wire.headers["Authorization"] == "Bearer k-1")

            let job = try catalog.jobs(revisionID: revisionID).first!
            #expect(job.state == .succeeded)
        }
    }

    /// The job row pins the prompt VERSION number; this build supplies the
    /// text. A job queued under a version this build does not know must
    /// fail closed — executing it with a different prompt would process
    /// the page under terms the user never approved. Re-enqueueing is the
    /// explicit fresh consent.
    @Test func unknownQueuedPromptVersionFailsClosedWithoutNetworkCall() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let (catalog, runner, credentials) = try makeFixture(transport: transport, directory: dir)
            try credentials.saveSecret("k-1", forProfileID: "p1")
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAI,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "m")
            let (_, revisionID) = try seedDocument(catalog: catalog)
            _ = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p1",
                                       modelID: "m", promptVersion: PromptVersion.current + 1, at: Date())

            await runner.drain(profileResolver: { _ in bound(profile) })

            #expect(transport.recorded.isEmpty)
            let job = try catalog.jobs(revisionID: revisionID).first!
            #expect(job.state == .failed)
            #expect(job.lastError?.contains("prompt version") == true)
        }
    }

    /// A resolver answer of nil — in the app this is a profile missing from
    /// the drain-time snapshot, e.g. no API key stored at drain start —
    /// fails the job visibly without any network call.
    @Test func unusablePairFailsVisiblyWithoutNetworkCall() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let (catalog, runner, _) = try makeFixture(transport: transport, directory: dir)
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAI,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "m")
            let (_, revisionID) = try seedDocument(catalog: catalog)
            _ = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p1",
                                       modelID: "m", promptVersion: 1, at: Date())
            await runner.drain(profileResolver: { _ in nil })
            #expect(transport.recorded.isEmpty)
            #expect(try catalog.activeJobs().isEmpty)
            let job = try catalog.jobs(revisionID: revisionID).first!
            #expect(job.state == .failed)
            #expect(job.lastError?.contains("API key") == true)
            _ = profile
        }
    }

    /// Mid-drain rotation must never cross origins: every request in a drain
    /// carries the endpoint+key pair resolved AT DRAIN START, as one unit.
    /// Before the pairing fix, the endpoint came from a profile snapshot
    /// while the key was re-fetched from the store for EVERY page — so a
    /// rotation saved mid-drain sent the NEW key to the OLD endpoint on
    /// later pages. Rotation takes effect on the NEXT drain instead.
    @Test func drainKeepsEndpointAndKeyCoherentWhenCredentialsRotateMidDrain() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            let credentials = InMemoryCredentialStore()
            let runner = OcrRunner(catalog: catalog, transport: transport,
                                   renderer: FixedRenderer(), clock: ManualClock())
            try credentials.saveSecret("KA", forProfileID: "p1")
            let profileA = ProviderProfile(id: "p1", displayName: "A", kind: .openAI,
                                           baseURL: URL(string: "https://api-a.example.com/v1")!, modelID: "m")
            let (_, revisionID) = try seedDocument(catalog: catalog, pages: 2)
            _ = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p1",
                                       modelID: "m", promptVersion: PromptVersion.current, at: Date())
            _ = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 1, profileID: "p1",
                                       modelID: "m", promptVersion: PromptVersion.current, at: Date())

            // The drain-time pair, captured before any rotation: A + KA.
            let drainPair = DrainCredential(profile: profileA, apiKey: "KA")
            // The user saves B/KB while the FIRST request is in flight:
            // the store now holds KB, and a save would point the profile at B.
            transport.onSend = { try? credentials.saveSecret("KB", forProfileID: "p1") }

            await runner.drain(profileResolver: { _ in drainPair })

            #expect(transport.recorded.count == 2)
            for (index, wire) in transport.recorded.enumerated() {
                #expect(wire.url.hasSuffix("api-a.example.com/v1/responses"),
                        "request \(index) must use the drain-time endpoint, not the rotated one")
                #expect(wire.headers["Authorization"] == "Bearer KA",
                        "request \(index) must carry the drain-time key, not the mid-drain rotation")
            }

            // The rotation goes live on the NEXT drain: re-enqueue one page
            // and drain with the freshly captured pair B/KB.
            _ = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p1",
                                       modelID: "m", promptVersion: PromptVersion.current, at: Date())
            transport.onSend = nil
            let profileB = ProviderProfile(id: "p1", displayName: "B", kind: .openAI,
                                           baseURL: URL(string: "https://api-b.example.com/v1")!, modelID: "m")
            let nextPair = DrainCredential(profile: profileB, apiKey: "KB")
            await runner.drain(profileResolver: { _ in nextPair })

            let last = try #require(transport.recorded.last)
            #expect(last.url.hasSuffix("api-b.example.com/v1/responses"))
            #expect(last.headers["Authorization"] == "Bearer KB")
        }
    }

    @Test func credentialNeverLeaksIntoJobErrors() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let (catalog, runner, credentials) = try makeFixture(transport: transport, directory: dir)
            let secret = "sk-super-secret-value"
            try credentials.saveSecret(secret, forProfileID: "p1")
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAI,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "m")
            let (_, revisionID) = try seedDocument(catalog: catalog)
            _ = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p1",
                                       modelID: "m", promptVersion: 1, at: Date())
            transport.enqueue(HTTPResponse(
                status: 400,
                body: Data("bad request with \(secret) inside".utf8)
            ))
            await runner.drain(profileResolver: { _ in bound(profile) })
            let job = try catalog.jobs(revisionID: revisionID).first!
            #expect(job.state == .failed)
            #expect(job.lastError != nil && !job.lastError!.contains(secret))
        }
    }


    @Test func lateResultForOldRevisionIsDiscarded() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let (catalog, runner, credentials) = try makeFixture(transport: transport, directory: dir)
            try credentials.saveSecret("k-1", forProfileID: "p1")
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAI,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "m")
            let (documentID, revisionV1) = try seedDocument(catalog: catalog)
            _ = try catalog.enqueueJob(revisionID: revisionV1, pageIndex: 0, profileID: "p1",
                                       modelID: "m", promptVersion: 1, at: Date())

            let samePath = try catalog.document(id: documentID)!.key.relativePath
            _ = try catalog.commitImport(
                key: DocumentKey(serial: "s", rootID: "r", relativePath: samePath),
                kind: .pdf, contentSHA256: UUID().uuidString, sizeBytes: 12, pageCount: 1,
                remoteMtime: 2, remoteSize: 12, at: Date()
            )

            await runner.drain(profileResolver: { _ in bound(profile) })

            let currentRevision = try catalog.currentRevisionID(documentID: documentID)!
            #expect(currentRevision != revisionV1)
            #expect(transport.recorded.isEmpty)
            let newPage = try catalog.pages(revisionID: currentRevision)[0]
            #expect(newPage.rawTranscription.isEmpty)
            #expect(newPage.effectiveText.isEmpty)
            let job = try catalog.jobs(revisionID: revisionV1).first!
            #expect(job.state == .failed)
            #expect(job.lastError?.contains("no longer current") == true)
        }
    }


    @Test func retryClassificationAndBounds() {
        let limits = RetryLimits(maxAttempts: 4, baseBackoffSeconds: 2, maxBackoffSeconds: 60, maxRetryAfterSeconds: 300)

        if case .retryAfter(let d, _) = RetryPolicy.decide(status: 429, retryAfterHeader: "7", attempt: 0, limits: limits) {
            #expect(d == 7)
        } else { Issue.record("429 must retry") }
        if case .retryAfter(let d, _) = RetryPolicy.decide(status: 429, retryAfterHeader: "99999", attempt: 0, limits: limits) {
            #expect(d == 300)
        } else { Issue.record("Retry-After must cap") }

        if case .retryAfter(let d, _) = RetryPolicy.decide(status: 503, retryAfterHeader: nil, attempt: 0, limits: limits) {
            #expect(d == 2)
        } else { Issue.record("503 must retry") }
        let capLimits = RetryLimits(maxAttempts: 10, baseBackoffSeconds: 2, maxBackoffSeconds: 60)
        if case .retryAfter(let d, _) = RetryPolicy.decide(status: 502, retryAfterHeader: nil, attempt: 5, limits: capLimits) {
            #expect(d == 60)
        } else { Issue.record("backoff must cap") }

        if case .fail = RetryPolicy.decide(status: 401, retryAfterHeader: nil, attempt: 0, limits: limits) {} else {
            Issue.record("401 must fail permanently")
        }
        if case .fail = RetryPolicy.decide(status: 400, retryAfterHeader: nil, attempt: 0, limits: limits) {} else {
            Issue.record("400 must fail permanently")
        }

        if case .fail = RetryPolicy.decide(status: 429, retryAfterHeader: "1", attempt: 4, limits: limits) {} else {
            Issue.record("attempts must be bounded")
        }
    }

    /// Integration proof: a 429 with Retry-After must make the drain loop
    /// sleep the provider-directed delay. The pure classifier test above
    /// passes either way — only observing the drain's actual sleep catches
    /// the delay being discarded between execute() and the requeue.
    @Test func drainHonorsProviderRetryAfter() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let clock = ManualClock()
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            let credentials = InMemoryCredentialStore()
            var limits = OcrRunnerLimits()
            limits.retry = RetryLimits(maxAttempts: 4, baseBackoffSeconds: 2, maxBackoffSeconds: 60, maxRetryAfterSeconds: 300)
            let runner = OcrRunner(catalog: catalog, transport: transport,
                                   renderer: FixedRenderer(), clock: clock, limits: limits)
            try credentials.saveSecret("k-1", forProfileID: "p1")
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAI,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "m")
            let (_, revisionID) = try seedDocument(catalog: catalog)
            _ = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p1",
                                       modelID: "m", promptVersion: 1, at: Date())

            transport.enqueue(HTTPResponse(
                status: 429, headers: ["retry-after": "37"],
                body: Data(#"{"error":{"message":"slow down"}}"#.utf8)
            ))
            transport.enqueue(HTTPResponse(status: 200, body: Data(#"{"output":[{"content":[{"type":"output_text","text":"page text"}]}]}"#.utf8)))
            await runner.drain(profileResolver: { $0 == "p1" ? bound(profile) : nil })

            // Exactly one requeue sleep, and it is the provider's 37s — not
            // the 2s local initial backoff the drain used to fall back to.
            #expect(clock.recordedSleeps == [37])
            let job = try catalog.jobs(revisionID: revisionID).first!
            #expect(job.state == .succeeded)
            #expect(job.attempts == 2)
            #expect(try catalog.pages(revisionID: revisionID)[0].rawTranscription == "page text")
        }
    }

    @Test func drainHonorsHTTPDateRetryAfter() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let clock = ManualClock()
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            let credentials = InMemoryCredentialStore()
            let runner = OcrRunner(catalog: catalog, transport: transport,
                                   renderer: FixedRenderer(), clock: clock)
            try credentials.saveSecret("k-1", forProfileID: "p1")
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAI,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "m")
            let (_, revisionID) = try seedDocument(catalog: catalog)
            _ = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p1",
                                       modelID: "m", promptVersion: 1, at: Date())

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let header = formatter.string(from: Date().addingTimeInterval(15))
            transport.enqueue(HTTPResponse(status: 429, headers: ["retry-after": header], body: Data()))
            transport.enqueue(HTTPResponse(status: 200, body: Data(#"{"output":[{"content":[{"type":"output_text","text":"page text"}]}]}"#.utf8)))
            await runner.drain(profileResolver: { _ in bound(profile) })

            #expect(clock.recordedSleeps.count == 1)
            let slept = clock.recordedSleeps.first ?? -1
            #expect(slept >= 12 && slept <= 20)
        }
    }

    @Test func drainCapsProviderRetryAfter() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let clock = ManualClock()
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            let credentials = InMemoryCredentialStore()
            var limits = OcrRunnerLimits()
            limits.retry = RetryLimits(maxAttempts: 4, baseBackoffSeconds: 2, maxBackoffSeconds: 60, maxRetryAfterSeconds: 300)
            let runner = OcrRunner(catalog: catalog, transport: transport,
                                   renderer: FixedRenderer(), clock: clock, limits: limits)
            try credentials.saveSecret("k-1", forProfileID: "p1")
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAI,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "m")
            let (_, revisionID) = try seedDocument(catalog: catalog)
            _ = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p1",
                                       modelID: "m", promptVersion: 1, at: Date())

            // A hostile or stuck header must not stall the queue for hours.
            transport.enqueue(HTTPResponse(status: 429, headers: ["retry-after": "99999"], body: Data()))
            transport.enqueue(HTTPResponse(status: 200, body: Data(#"{"output":[{"content":[{"type":"output_text","text":"page text"}]}]}"#.utf8)))
            await runner.drain(profileResolver: { _ in bound(profile) })

            #expect(clock.recordedSleeps == [300])
            let job = try catalog.jobs(revisionID: revisionID).first!
            #expect(job.state == .succeeded)
            #expect(job.attempts == 2)
        }
    }


    /// The probe takes its key EXPLICITLY (ephemeral draft key from the
    /// Settings flow, never the store): the wire call must carry exactly the
    /// supplied key even though the store still holds a different one, and
    /// the store is untouched by the probe.
    @Test func capabilityProbeUsesSuppliedKeyAndLeavesTheStoreUntouched() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let (_, runner, credentials) = try makeFixture(transport: transport, directory: dir)
            try credentials.saveSecret("stored-KA", forProfileID: "p1")
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAICompatible,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "vision-model")

            transport.enqueue(HTTPResponse(status: 200, body: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)))
            let result = await runner.probeImageCapability(profile: profile, apiKey: "draft-KB")

            #expect(result == .verified)
            #expect(transport.recorded.count == 1)
            let wire = try #require(transport.recorded.first)
            #expect(wire.url.hasSuffix("api.example.com/v1/chat/completions"))
            #expect(wire.headers["Authorization"] == "Bearer draft-KB",
                    "the probe must send the explicitly supplied ephemeral key, not the stored one")
            #expect(try credentials.secret(forProfileID: "p1") == "stored-KA",
                    "probing must not mutate the stored credential")
        }
    }

    /// Wire-level fail-closed check: with no key of any kind, the probe is
    /// refused before any network call.
    @Test func capabilityProbeWithoutKeyNeverReachesNetwork() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let (_, runner, _) = try makeFixture(transport: transport, directory: dir)
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAICompatible,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "vision-model")

            let result = await runner.probeImageCapability(profile: profile, apiKey: "")

            if case .rejected(let reason) = result {
                #expect(reason.contains("API key"))
            } else {
                Issue.record("missing key must reject")
            }
            #expect(transport.recorded.isEmpty, "no key must mean no wire call")
        }
    }

    @Test func capabilityProbeScenarios() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let (_, runner, credentials) = try makeFixture(transport: transport, directory: dir)
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAICompatible,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "vision-model")

            transport.enqueue(HTTPResponse(status: 200, body: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)))
            #expect(await runner.probeImageCapability(profile: profile, apiKey: "k-1") == .verified)

            transport.enqueue(HTTPResponse(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8)))
            if case .rejected(let reason) = await runner.probeImageCapability(profile: profile, apiKey: "bad") {
                #expect(reason.contains("authentication"))
            } else { Issue.record("401 must reject as auth") }

            transport.enqueue(HTTPResponse(status: 415, body: Data()))
            if case .rejected(let reason) = await runner.probeImageCapability(profile: profile, apiKey: "k-1") {
                #expect(reason.contains("image"))
            } else { Issue.record("415 must reject as image-unsupported") }

            let body = String(data: transport.recorded.last!.body, encoding: .utf8)!
            #expect(body.contains(SyntheticProbeImage.png.base64EncodedString()))
            #expect(body.contains(ProviderWire.syntheticTestPrompt))

            let unsafe = ProviderProfile(id: "p1", displayName: "U", kind: .openAI,
                                         baseURL: URL(string: "http://api.example.com/v1")!, modelID: "m")
            if case .rejected(let reason) = await runner.probeImageCapability(profile: unsafe, apiKey: "k-1") {
                #expect(reason.contains("loopback"))
            } else { Issue.record("plain http off-loopback must be rejected") }
            _ = credentials // fixture store: no longer consulted by the probe
        }
    }


    @Test func transcriptExportPreservesOrderAndEdits() throws {
        let exporter = TranscriptExporter()
        let pages = [
            PageTranscript(id: 1, revisionID: 1, pageIndex: 0, rawTranscription: "raw zero",
                           effectiveText: "edited zero", lastEditedAt: Date()),
            PageTranscript(id: 2, revisionID: 1, pageIndex: 1, rawTranscription: "page one",
                           effectiveText: "", lastEditedAt: nil),
        ]
        let text = exporter.export(title: "Meeting", pages: pages, format: .plainText)
        // Edits take precedence; a page with no edit falls back to the raw transcription.
        #expect(text.contains("edited zero"))
        #expect(!text.contains("raw zero"))
        #expect(text.contains("page one"))
        #expect(text.range(of: "Page 1")!.lowerBound < text.range(of: "Page 2")!.lowerBound)

        let md = exporter.export(title: "Meeting", pages: pages, format: .markdown)
        #expect(md.hasPrefix("# Meeting"))
        #expect(md.contains("## Page 1"))
        #expect(md.contains("## Page 2"))
    }
}
