import Foundation
import Testing
@testable import BooxBridgeCore

// Regression coverage for re-enqueue semantics. The ocr_jobs schema keeps a
// single row per (revision, page, profile, model, prompt) identity in every
// state, so enqueueJob must reset a terminal row (succeeded / failed /
// cancelled) back to queued instead of inserting a duplicate the UNIQUE
// constraint rejects. Before the fix, re-enqueuing any terminal page threw
// a constraint error, and the app layer — which swallows store errors and
// counts enqueues by non-nil returns — silently reported zero queued pages.

@Suite struct JobReenqueueTests {
    /// Queued-response transport: replies in FIFO order, empty body-safe
    /// default once the script runs out. Self-contained so this file does
    /// not depend on the OCR queue suite's fixtures.
    private final class ReplayTransport: HTTPTransporting, @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [HTTPResponse] = []

        func enqueue(_ response: HTTPResponse) {
            lock.lock(); defer { lock.unlock() }
            responses.append(response)
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            nextResponse()
        }

        private func nextResponse() -> HTTPResponse {
            lock.lock(); defer { lock.unlock() }
            guard !responses.isEmpty else {
                return HTTPResponse(status: 200, body: Data(
                    #"{"output":[{"content":[{"type":"output_text","text":"default"}]}]}"#.utf8))
            }
            return responses.removeFirst()
        }
    }

    private struct StillRenderer: PageRendering {
        func pngData(revisionSHA256: String, pageIndex: Int, maxDimensionPoints: CGFloat) throws -> Data {
            SyntheticProbeImage.png
        }
    }

    private func makeFixture(
        directory: URL, transport: ReplayTransport
    ) throws -> (CatalogStore, OcrRunner, InMemoryCredentialStore) {
        let catalog = try CatalogStore.open(atPath: directory.appendingPathComponent("c.sqlite").path)
        let credentials = InMemoryCredentialStore()
        let runner = OcrRunner(
            catalog: catalog, transport: transport, credentials: credentials,
            renderer: StillRenderer(), clock: ManualClock()
        )
        return (catalog, runner, credentials)
    }

    private func seedRevision(in catalog: CatalogStore) throws -> (Int64, Int64) {
        let outcome = try catalog.commitImport(
            key: DocumentKey(serial: "s", rootID: "r", relativePath: "note-\(UUID().uuidString).pdf"),
            kind: .pdf, contentSHA256: UUID().uuidString, sizeBytes: 10, pageCount: 1,
            remoteMtime: 1, remoteSize: 10, at: Date()
        )
        guard case .newDocument(let documentID, let revisionID) = outcome else {
            fatalError("seed failed")
        }
        return (documentID, revisionID)
    }

    private func transcription(_ text: String) -> HTTPResponse {
        let body = "{\"output\":[{\"content\":[{\"type\":\"output_text\",\"text\":\"\(text)\"}]}]}"
        return HTTPResponse(status: 200, body: Data(body.utf8))
    }

    private func enqueue(
        _ catalog: CatalogStore, revisionID: Int64,
        profileID: String = "p1", modelID: String = "m", promptVersion: Int = 1
    ) throws -> Int64 {
        guard let id = try catalog.enqueueJob(
            revisionID: revisionID, pageIndex: 0, profileID: profileID,
            modelID: modelID, promptVersion: promptVersion, at: Date()
        ) else {
            Issue.record("expected a job id, got deduplicated nil")
            return -1
        }
        return id
    }

    /// A succeeded page re-enqueued with the exact same identity must
    /// re-process: the terminal row resets to queued and the next drain
    /// overwrites the stored transcription. Failed on the old behavior,
    /// which raised the UNIQUE-constraint error instead.
    @Test func succeededJobIsReprocessedOnSameIdentityEnqueue() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ReplayTransport()
            let (catalog, runner, credentials) = try makeFixture(directory: dir, transport: transport)
            try credentials.saveSecret("k-1", forProfileID: "p1")
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAI,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "m")
            let (_, revisionID) = try seedRevision(in: catalog)

            transport.enqueue(transcription("first pass"))
            let firstID = try enqueue(catalog, revisionID: revisionID)
            await runner.drain(profileResolver: { _ in profile })
            #expect(try catalog.job(id: firstID)!.state == .succeeded)
            #expect(try catalog.pages(revisionID: revisionID)[0].effectiveText == "first pass")

            let resetID = try enqueue(catalog, revisionID: revisionID)
            #expect(resetID == firstID)
            let reset = try catalog.job(id: resetID)!
            #expect(reset.state == .queued)
            #expect(reset.attempts == 0)
            #expect(reset.lastError == nil)
            #expect(reset.runAt == nil)

            transport.enqueue(transcription("second pass"))
            await runner.drain(profileResolver: { _ in profile })

            let after = try catalog.pages(revisionID: revisionID)[0]
            #expect(after.rawTranscription == "second pass")
            #expect(after.effectiveText == "second pass")
            #expect(try catalog.job(id: firstID)!.state == .succeeded)
            #expect(try catalog.job(id: firstID)!.attempts == 1)
        }
    }

    /// A failed page re-enqueued with the exact same identity must retry:
    /// the failed row resets (attempt counter to zero, error cleared) and
    /// the next drain runs it to completion. Failed on the old behavior,
    /// which raised the UNIQUE-constraint error instead.
    @Test func failedJobRetriesOnSameIdentityEnqueue() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = ReplayTransport()
            let (catalog, runner, credentials) = try makeFixture(directory: dir, transport: transport)
            let profile = ProviderProfile(id: "p1", displayName: "P", kind: .openAI,
                                          baseURL: URL(string: "https://api.example.com/v1")!, modelID: "m")
            let (_, revisionID) = try seedRevision(in: catalog)

            // First pass fails before any network call: no API key stored.
            let jobID = try enqueue(catalog, revisionID: revisionID)
            await runner.drain(profileResolver: { _ in profile })
            let failed = try catalog.job(id: jobID)!
            #expect(failed.state == .failed)
            #expect(failed.lastError?.contains("API key") == true)
            #expect(failed.attempts == 1)

            let retriedID = try enqueue(catalog, revisionID: revisionID)
            #expect(retriedID == jobID)
            let reset = try catalog.job(id: retriedID)!
            #expect(reset.state == .queued)
            #expect(reset.attempts == 0)
            #expect(reset.lastError == nil)

            try credentials.saveSecret("k-1", forProfileID: "p1")
            transport.enqueue(transcription("recovered text"))
            await runner.drain(profileResolver: { _ in profile })

            #expect(try catalog.pages(revisionID: revisionID)[0].rawTranscription == "recovered text")
            let done = try catalog.job(id: jobID)!
            #expect(done.state == .succeeded)
            #expect(done.attempts == 1)
        }
    }

    /// A cancelled page is terminal but overridable: re-enqueue resumes it.
    /// Failed on the old behavior, which raised the UNIQUE-constraint error.
    @Test func cancelledJobResumesOnSameIdentityEnqueue() async throws {
        try await withTempDirectoryAsync { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            let (_, revisionID) = try seedRevision(in: catalog)

            let jobID = try enqueue(catalog, revisionID: revisionID)
            try catalog.updateJob(id: jobID, state: .cancelled, attempts: 2,
                                  lastError: "cancelled", at: Date())

            let resumedID = try enqueue(catalog, revisionID: revisionID)
            #expect(resumedID == jobID)
            let resumed = try catalog.job(id: jobID)!
            #expect(resumed.state == .queued)
            #expect(resumed.attempts == 0)
            #expect(resumed.lastError == nil)
        }
    }

    /// The flip side of the contract: an active (queued or running) job is
    /// still deduplicated — re-enqueue returns nil and leaves the row
    /// untouched, so a concurrent duplicate enqueue can never clobber
    /// in-flight work.
    @Test func activeJobStillDeduplicatesWithoutReset() async throws {
        try await withTempDirectoryAsync { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            let (_, revisionID) = try seedRevision(in: catalog)

            let queuedID = try enqueue(catalog, revisionID: revisionID)
            #expect(try catalog.enqueueJob(
                revisionID: revisionID, pageIndex: 0, profileID: "p1",
                modelID: "m", promptVersion: 1, at: Date()
            ) == nil)

            try catalog.updateJob(id: queuedID, state: .running, attempts: 1,
                                  lastError: nil, at: Date())
            #expect(try catalog.enqueueJob(
                revisionID: revisionID, pageIndex: 0, profileID: "p1",
                modelID: "m", promptVersion: 1, at: Date()
            ) == nil)
            let running = try catalog.job(id: queuedID)!
            #expect(running.state == .running)
            #expect(running.attempts == 1)
        }
    }
}
