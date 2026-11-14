import Foundation
import Testing
@testable import BooxBridgeCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite struct ProviderWireTests {
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    func request(_ profile: ProviderProfile) throws -> WireRequest {
        try ProviderWire.makeRequest(
            profile: profile, apiKey: "sk-test-123", prompt: "TRANSCRIBE",
            imagePNGData: png
        )
    }


    @Test func openAIResponsesContract() throws {
        let wire = try request(ProviderPresets.openAI)
        #expect(wire.url.absoluteString == "https://api.openai.com/v1/responses")
        #expect(wire.headers["Authorization"] == "Bearer sk-test-123")
        #expect(wire.headers["Content-Type"] == "application/json")

        let json = try JSONSerialization.jsonObject(with: wire.body) as! [String: Any]
        #expect(json["model"] as! String == "gpt-4o-mini")
        #expect(json["max_output_tokens"] as! Int == 4096)
        let input = json["input"] as! [[String: Any]]
        #expect(input.count == 1)
        #expect(input[0]["role"] as! String == "user")
        let content = input[0]["content"] as! [[String: Any]]
        #expect(content.count == 2)
        #expect(content[0]["type"] as! String == "input_text")
        #expect(content[0]["text"] as! String == "TRANSCRIBE")
        let image = content[1]
        #expect(image["type"] as! String == "input_image")
        let url = image["image_url"] as! String
        #expect(url.hasPrefix("data:image/png"))
        #expect(url.contains("detail=high"))
        #expect(url.contains(png.base64EncodedString()))
    }

    @Test func anthropicMessagesContract() throws {
        let wire = try request(ProviderPresets.anthropic)
        #expect(wire.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(wire.headers["x-api-key"] == "sk-test-123")
        #expect(wire.headers["anthropic-version"] == "2023-06-01")
        #expect(wire.headers["Authorization"] == nil)

        let json = try JSONSerialization.jsonObject(with: wire.body) as! [String: Any]
        #expect(json["model"] as! String == "claude-sonnet-4-5")
        #expect(json["max_tokens"] as! Int == 4096)
        let messages = json["messages"] as! [[String: Any]]
        let content = messages[0]["content"] as! [[String: Any]]
        #expect(content[0]["type"] as! String == "image")
        let source = content[0]["source"] as! [String: Any]
        #expect(source["type"] as! String == "base64")
        #expect(source["media_type"] as! String == "image/png")
        #expect(source["data"] as! String == png.base64EncodedString())
        #expect(content[1]["type"] as! String == "text")
        #expect(content[1]["text"] as! String == "TRANSCRIBE")
    }

    @Test func openAICompatibleContract() throws {
        for preset in [ProviderPresets.deepInfra, ProviderPresets.zai] {
            let wire = try request(preset)
            #expect(wire.url.absoluteString == preset.baseURL.absoluteString + "/chat/completions")
            #expect(wire.headers["Authorization"] == "Bearer sk-test-123")
            let json = try JSONSerialization.jsonObject(with: wire.body) as! [String: Any]
            #expect(json["model"] as! String == preset.modelID)
            let messages = json["messages"] as! [[String: Any]]
            #expect(messages[0]["role"] as! String == "user")
            let content = messages[0]["content"] as! [[String: Any]]
            #expect(content[0]["type"] as! String == "text")
            let image = content[1]["image_url"] as! [String: Any]
            #expect((image["url"] as! String).hasPrefix("data:image/png;base64,"))
            #expect(json["tools"] == nil)
            #expect(json["functions"] == nil)
        }
    }

    @Test func responseDecodingPerKind() throws {
        let openAI = #"{"output":[{"content":[{"type":"output_text","text":"hello notes"}]}]}"#
        #expect(try ProviderWire.decodeTranscription(kind: .openAI, body: Data(openAI.utf8)) == "hello notes")
        let anthropic = #"{"content":[{"type":"text","text":"line one"},{"type":"text","text":"line two"}]}"#
        #expect(try ProviderWire.decodeTranscription(kind: .anthropic, body: Data(anthropic.utf8)) == "line one\nline two")
        let chat = #"{"choices":[{"message":{"content":"body text"}}]}"#
        #expect(try ProviderWire.decodeTranscription(kind: .openAICompatible, body: Data(chat.utf8)) == "body text")

        #expect(throws: WireError.emptyTranscription.self) {
            _ = try ProviderWire.decodeTranscription(kind: .openAI, body: Data(#"{"output":[]}"#.utf8))
        }
        #expect(throws: WireError.self) {
            _ = try ProviderWire.decodeTranscription(kind: .anthropic, body: Data("not json".utf8))
        }
        #expect(throws: WireError.emptyResponse.self) {
            _ = try ProviderWire.decodeTranscription(kind: .openAICompatible, body: Data())
        }
        #expect(throws: WireError.malformedResponse("provider error: bad model")) {
            _ = try ProviderWire.decodeTranscription(kind: .openAICompatible, body: Data(#"{"error":{"message":"bad model"}}"#.utf8))
        }
    }

    @Test func promptIsTranscriptionInputOnly() {
        #expect(PromptVersion.text.contains("Transcribe"))
        #expect(PromptVersion.text.contains("[unreadable]"))
        #expect(!PromptVersion.text.lowercased().contains("ignore previous"))
    }
}

@Suite struct EndpointSecurityTests {

    @Test func httpsEndpointsAllowed() {
        #expect(EndpointPolicy.validate(url: URL(string: "https://api.openai.com/v1")!) == .allowed)
        #expect(EndpointPolicy.validate(url: URL(string: "https://api.z.ai:8443/api/paas/v4")!) == .allowed)
    }

    @Test func plainHTTPOnlyOnLoopback() {
        #expect(EndpointPolicy.validate(url: URL(string: "http://localhost:8080/v1")!) == .allowed)
        #expect(EndpointPolicy.validate(url: URL(string: "http://127.0.0.1:3000/v1")!) == .allowed)
        if case .rejected = EndpointPolicy.validate(url: URL(string: "http://api.openai.com/v1")!) {} else {
            Issue.record("plain http to a public host must be rejected")
        }
        if case .rejected = EndpointPolicy.validate(url: URL(string: "ftp://example.com")!) {} else {
            Issue.record("non-http(s) schemes must be rejected")
        }
    }

    @Test func userinfoAndQueryCredentialsRejected() {
        if case .rejected = EndpointPolicy.validate(url: URL(string: "https://user:pass@api.example.com/v1")!) {} else {
            Issue.record("userinfo credentials must be rejected")
        }
        if case .rejected = EndpointPolicy.validate(url: URL(string: "https://api.example.com/v1?key=abc")!) {} else {
            Issue.record("key in query must be rejected")
        }
        if case .rejected = EndpointPolicy.validate(url: URL(string: "https://api.example.com/v1?access_token=abc")!) {} else {
            Issue.record("token in query must be rejected")
        }
        #expect(EndpointPolicy.validate(url: URL(string: "https://api.example.com/v1?verbose=true")!) == .allowed)
    }

    @Test func redirectsNeverCrossOriginOrDowngrade() {
        let original = URL(string: "https://api.example.com/v1/chat")!
        #expect(EndpointPolicy.redirectAllowed(from: original, to: URL(string: "https://api.example.com/v2/chat")!))
        #expect(!EndpointPolicy.redirectAllowed(from: original, to: URL(string: "https://evil.example.net/v1")!))
        #expect(!EndpointPolicy.redirectAllowed(from: original, to: URL(string: "http://api.example.com/v1")!))
        #expect(EndpointPolicy.redirectAllowed(from: original, to: URL(string: "https://API.Example.Com/v2")!))
    }

    @Test func redirectsRejectCrossPortSameHost() {
        // A different port is a different origin even when the host matches:
        // the Authorization key must not follow https://host:443 -> https://host:8443.
        let original = URL(string: "https://api.example.com:443/v1/chat")!
        #expect(!EndpointPolicy.redirectAllowed(from: original, to: URL(string: "https://api.example.com:8443/v1/chat")!))
        #expect(!EndpointPolicy.redirectAllowed(
            from: URL(string: "http://127.0.0.1:8080/v1")!,
            to: URL(string: "http://127.0.0.1:9090/v1")!
        ))
    }

    @Test func redirectsTreatExplicitDefaultPortAsSameOrigin() {
        // An explicit default port is the same origin as its absence.
        let original = URL(string: "https://api.example.com:443/v1/chat")!
        #expect(EndpointPolicy.redirectAllowed(from: original, to: URL(string: "https://api.example.com/v1/chat")!))
        #expect(EndpointPolicy.redirectAllowed(from: URL(string: "http://localhost:80/v1")!, to: URL(string: "http://localhost/v1/again")!))
    }

    @Test func redirectTargetMustPassFullEndpointPolicy() {
        let original = URL(string: "https://api.example.com/v1/chat")!
        // Hostname-only matching used to wave these through; the target must
        // satisfy the full policy on its own.
        #expect(!EndpointPolicy.redirectAllowed(from: original, to: URL(string: "https://user:pass@api.example.com/v1")!))
        #expect(!EndpointPolicy.redirectAllowed(from: original, to: URL(string: "https://api.example.com/v1?key=leaked")!))
        #expect(!EndpointPolicy.redirectAllowed(from: original, to: URL(string: "ftp://api.example.com/v1")!))
    }

    @Test func redirectsWithinLoopbackHTTPOriginAllowed() {
        // Loopback http is a legal endpoint, so a same-origin loopback
        // redirect keeps the request on the origin it was aimed at.
        let original = URL(string: "http://127.0.0.1:8080/v1/chat")!
        #expect(EndpointPolicy.redirectAllowed(from: original, to: URL(string: "http://127.0.0.1:8080/v1/again")!))
        #expect(EndpointPolicy.redirectAllowed(from: URL(string: "http://[::1]:8080/v1")!, to: URL(string: "http://[::1]:8080/v1/again")!))
        #expect(!EndpointPolicy.redirectAllowed(from: URL(string: "http://[::1]:8080/v1")!, to: URL(string: "http://127.0.0.1:8080/v1")!))
    }
}

/// Minimal TCP listener for transport tests: accepts one loopback
/// connection and never sends a byte, so the only ways an in-flight
/// request can end are cancellation or the session's own timeouts.
final class HangServer: @unchecked Sendable {
    enum AcceptMode {
        /// HangServer accepts by itself and never responds.
        case hangOnce
        /// The owner drives acceptBlocking(); no competing accept thread.
        /// Two blocked accept() calls on one listener race for the single
        /// connection, so a reply-serving variant must use this mode.
        case manual
    }

    private let lock = NSLock()
    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var connected = false
    private let acceptMode: AcceptMode
    private(set) var port: UInt16 = 0

    struct SetupFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    init(acceptMode: AcceptMode = .hangOnce) throws {
        self.acceptMode = acceptMode
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else {
            throw SetupFailure(message: "socket: \(String(cString: strerror(errno)))")
        }
        serverFD = fd
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // ephemeral; the bound port is read back below
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw SetupFailure(message: "bind: \(String(cString: strerror(errno)))")
        }
        guard listen(fd, 1) == 0 else {
            throw SetupFailure(message: "listen: \(String(cString: strerror(errno)))")
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var bound = sockaddr_in()
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &length)
            }
        }
        guard nameResult == 0 else {
            throw SetupFailure(message: "getsockname: \(String(cString: strerror(errno)))")
        }
        port = UInt16(bigEndian: bound.sin_port)

        // A blocking accept must not occupy a cooperative thread pool slot.
        if acceptMode == .hangOnce {
            let thread = Thread { [weak self] in self?.acceptOne() }
            thread.name = "hang-server-accept"
            thread.start()
        }
    }

    private func acceptOne() {
        _ = acceptBlocking()
        // Never read a response and never write: the request hangs.
    }

    /// Blocking accept for the ReplyServer wrapper. The caller owns the
    /// returned descriptor only for reading and writing; HangServer.stop()
    /// closes it, so wrappers must not close it themselves.
    func acceptBlocking() -> Int32? {
        let fd = accept(serverFD, nil, nil)
        guard fd >= 0 else { return nil }
        lock.lock()
        clientFD = fd
        connected = true
        lock.unlock()
        return fd
    }

    /// NSLock is unavailable in async contexts, so async callers go through
    /// these synchronous snapshots (same pattern as ManualClock).
    private func isConnectedSnapshot() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return connected
    }

    private func clientFDSnapshot() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return clientFD
    }

    @discardableResult
    func waitUntilConnected(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isConnectedSnapshot() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Polls the accepted socket until the peer closes it. Observing EOF is
    /// the proof that the in-flight request was actually torn down instead
    /// of left open until a session timeout.
    @discardableResult
    func observedEOF(within timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 128)
        while Date() < deadline {
            let fd = clientFDSnapshot()
            if fd >= 0 {
                #if canImport(Glibc)
                let count = recv(fd, &buffer, buffer.count, Int32(MSG_DONTWAIT))
                #else
                let count = recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
                #endif
                if count == 0 { return true }
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    func stop() {
        lock.lock()
        let server = serverFD
        let client = clientFD
        serverFD = -1
        clientFD = -1
        lock.unlock()
        if client >= 0 { close(client) }
        if server >= 0 {
            shutdown(server, Int32(SHUT_RDWR))
            close(server)
        }
    }

    deinit { stop() }
}

/// Variant of the listener that answers the first request immediately,
/// for proving the transport completes ordinary requests.
final class ReplyServer: @unchecked Sendable {
    private let server: HangServer
    private var thread: Thread?
    private let response: String

    var port: UInt16 { server.port }

    init(response: String) throws {
        self.response = response
        // Manual mode: the reply thread below is the only accepter.
        self.server = try HangServer(acceptMode: .manual)
        let thread = Thread { [weak self] in self?.replyOnce() }
        thread.name = "reply-server"
        thread.start()
        self.thread = thread
    }

    private func replyOnce() {
        guard let fd = server.acceptBlocking() else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = recv(fd, &buffer, buffer.count, 0)
        _ = response.withCString { pointer in
            send(fd, pointer, strlen(pointer), 0)
        }
        // Leave the descriptor open: HangServer.stop() closes it, and
        // closing here would race a later stop() on a reused fd number.
    }

    func stop() { server.stop() }
}

/// Serial on purpose: Linux FoundationNetworking can fail to start a
/// session's transfer when several sessions begin transfers at once, so
/// these transport tests run one at a time.
/// Shared flag letting the detached watchdog tell "operation finished"
/// from "operation wedged" once its timer fires.
private final class WatchdogSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

/// Bounds a hang-prone network await so a stalled transport fails the test
/// loudly instead of wedging the whole runner. The watchdog must stay
/// UNSTRUCTURED: as a task-group timer it was a sibling of the guarded
/// operation, so when a stranded continuation never resumed, the timer
/// won but the group still awaited the hung child — the runner wedged
/// forever instead of reporting a failure. A detached task instead records
/// the failure and, because a wedged test can never return on its own,
/// escalates to a nonzero process exit, the only failure signal that can
/// escape the wedge.
private func withWatchdog<T: Sendable>(_ seconds: TimeInterval,
                                       _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let signal = WatchdogSignal()
    let watchdog = Task.detached(priority: .userInitiated) {
        try? await Task.sleep(for: .seconds(seconds))
        if signal.isFinished { return }
        // Short grace so a completion racing the deadline is not misjudged.
        try? await Task.sleep(for: .milliseconds(500))
        guard !signal.isFinished else { return }
        Issue.record("operation exceeded its \(seconds)s watchdog; a stranded continuation is wedging this test")
        // Give the runner a moment to flush the recorded issue, then break
        // the wedge: a test that can never return only fails by process exit.
        usleep(500_000)
        FileHandle.standardError.write(Data(
            "watchdog: operation exceeded \(seconds)s; exiting nonzero so a stranded continuation cannot wedge the test runner\n".utf8
        ))
        exit(2)
    }
    defer {
        signal.finish()
        watchdog.cancel()
    }
    return try await operation()
}

@Suite(.serialized)
struct TransportCancellationTests {

    /// The transport must complete ordinary requests end-to-end. This path
    /// silently never completed on Linux FoundationNetworking while the
    /// delegate was attached to the task instead of the session.
    @Test func requestAgainstLocalServerCompletes() async throws {
        let server = try ReplyServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        defer { server.stop() }

        let transport = URLSessionTransport()
        let request = HTTPRequest(
            url: URL(string: "http://127.0.0.1:\(server.port)/v1/responses")!,
            body: Data(#"{"model":"m"}"#.utf8)
        )
        let response = try await withWatchdog(20) {
            try await transport.send(request)
        }
        #expect(response.status == 200)
        #expect(response.body == Data("ok".utf8))
    }

    /// A cancelled Task must interrupt an in-flight request: send() fails
    /// fast with CancellationError and the connection is torn down, instead
    /// of the await sitting out the full session timeout on a hung request.
    @Test func cancelledTaskInterruptsInFlightRequest() async throws {
        let server = try HangServer()
        defer { server.stop() }

        let transport = URLSessionTransport()
        let request = HTTPRequest(
            url: URL(string: "http://127.0.0.1:\(server.port)/v1/responses")!,
            body: Data(#"{"model":"m"}"#.utf8)
        )

        let started = Date()
        let call = Task {
            try await withWatchdog(20) { try await transport.send(request) }
        }

        // Cancel only once the request is genuinely in flight: the server
        // side accept proves the transport already connected.
        #expect(await server.waitUntilConnected(timeout: 10))

        call.cancel()
        do {
            _ = try await call.value
            Issue.record("send must not complete normally after cancellation")
        } catch {
            #expect(error is CancellationError, "expected cancellation, got: \(error)")
        }
        // Must return promptly — well before the transport's own 120s
        // request timeout, which is what a missing cancel bridge would hit.
        #expect(Date().timeIntervalSince(started) < 30)

        #expect(await server.observedEOF(within: 5))
    }

    /// Sending to a hung server with no cancellation still surfaces as a
    /// transport failure (not cancellation), confirming the two outcomes
    /// stay distinguishable.
    @Test func hungRequestWithoutCancellationSurfacesAsTransportFailure() async throws {
        let server = try HangServer()
        defer { server.stop() }

        // Short session timeouts keep this test fast: the hung request must
        // fail on its own, as a transport error distinct from cancellation.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        let transport = URLSessionTransport(configuration: config)
        let request = HTTPRequest(
            url: URL(string: "http://127.0.0.1:\(server.port)/v1/responses")!,
            body: Data(#"{"model":"m"}"#.utf8)
        )

        do {
            _ = try await withWatchdog(20) {
                try await transport.send(request)
            }
            Issue.record("a hung request must fail, not succeed")
        } catch let failure as HTTPFailure {
            if case .transportError = failure {} else {
                Issue.record("expected a transport error, got: \(failure)")
            }
        } catch {
            Issue.record("expected an HTTPFailure, got: \(error)")
        }
    }
}
