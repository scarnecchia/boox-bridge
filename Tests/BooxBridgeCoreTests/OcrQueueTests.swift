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

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try nextResponse(for: request)
    }

    private func nextResponse(for request: HTTPRequest) throws -> HTTPResponse {
        lock.lock(); defer { lock.unlock() }
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
            catalog: catalog, transport: transport, credentials: credentials,
            renderer: FixedRenderer(), clock: ManualClock()
        )
        return (catalog, runner, credentials)
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
            await runner.drain(profileResolver: { $0 == "p1" ? profile : nil })

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
            await runner.drain(profileResolver: { _ in profile })

            let pages = try catalog.pages(revisionID: revisionID)
            try catalog.updateEffectiveText(pageID: pages[0].id, text: "my edited version", at: Date())

            transport.enqueue(HTTPResponse(status: 200, body: Data(#"{"output":[{"content":[{"type":"output_text","text":"raw two"}]}]}"#.utf8)))
            _ = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p1",
                                       modelID: "m2", promptVersion: 1, at: Date())
            await runner.drain(profileResolver: { _ in profile })

            let after = try catalog.pages(revisionID: revisionID)[0]
            #expect(after.rawTranscription == "raw two")
            #expect(after.effectiveText == "my edited version")
            #expect(after.lastEditedAt != nil)
        }
    }

    @Test func missingKeyFailsVisiblyWithoutNetworkCall() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let (catalog, runner, _) = try makeFixture(transport: transport, directory: dir)
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAI,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "m")
            let (_, revisionID) = try seedDocument(catalog: catalog)
            _ = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p1",
                                       modelID: "m", promptVersion: 1, at: Date())
            await runner.drain(profileResolver: { _ in profile })
            #expect(transport.recorded.isEmpty)
            #expect(try catalog.activeJobs().isEmpty)
            let job = try catalog.jobs(revisionID: revisionID).first!
            #expect(job.state == .failed)
            #expect(job.lastError?.contains("API key") == true)
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
            await runner.drain(profileResolver: { _ in profile })
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
            try catalog.commitImport(
                key: DocumentKey(serial: "s", rootID: "r", relativePath: samePath),
                kind: .pdf, contentSHA256: UUID().uuidString, sizeBytes: 12, pageCount: 1,
                remoteMtime: 2, remoteSize: 12, at: Date()
            )

            await runner.drain(profileResolver: { _ in profile })

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


    @Test func capabilityProbeScenarios() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ScriptedTransport()
            let (_, runner, credentials) = try makeFixture(transport: transport, directory: dir)
            try credentials.saveSecret("k-1", forProfileID: "p1")
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAICompatible,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "vision-model")

            transport.enqueue(HTTPResponse(status: 200, body: Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)))
            #expect(await runner.probeImageCapability(profile: profile) == .verified)

            try credentials.saveSecret("bad", forProfileID: "p1")
            transport.enqueue(HTTPResponse(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8)))
            if case .rejected(let reason) = await runner.probeImageCapability(profile: profile) {
                #expect(reason.contains("authentication"))
            } else { Issue.record("401 must reject as auth") }

            transport.enqueue(HTTPResponse(status: 415, body: Data()))
            if case .rejected(let reason) = await runner.probeImageCapability(profile: profile) {
                #expect(reason.contains("image"))
            } else { Issue.record("415 must reject as image-unsupported") }

            let body = String(data: transport.recorded.last!.body, encoding: .utf8)!
            #expect(body.contains(SyntheticProbeImage.png.base64EncodedString()))
            #expect(body.contains(ProviderWire.syntheticTestPrompt))

            let keyless = ProviderProfile(id: "nokey", displayName: "N", kind: .openAI,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "m")
            if case .rejected(let reason) = await runner.probeImageCapability(profile: keyless) {
                #expect(reason.contains("API key"))
            } else { Issue.record("missing key must reject") }

            let unsafe = ProviderProfile(id: "p1", displayName: "U", kind: .openAI,
                                         baseURL: URL(string: "http://api.example.com/v1")!, modelID: "m")
            if case .rejected(let reason) = await runner.probeImageCapability(profile: unsafe) {
                #expect(reason.contains("loopback"))
            } else { Issue.record("plain http off-loopback must be rejected") }
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
