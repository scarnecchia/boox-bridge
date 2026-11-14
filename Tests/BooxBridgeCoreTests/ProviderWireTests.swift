// providerWireContractFixtures + endpointSecurityFixtures.
import Foundation
import Testing
@testable import BooxBridgeCore

@Suite struct ProviderWireTests {
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    func request(_ profile: ProviderProfile) throws -> WireRequest {
        try ProviderWire.makeRequest(
            profile: profile, apiKey: "sk-test-123", prompt: "TRANSCRIBE",
            imagePNGData: png
        )
    }

    // -- providerWireContractFixtures --------------------------------------

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
        #expect(url.contains("detail=high")) // preset detail hint applied
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
            // No tools/function fields are ever sent.
            #expect(json["tools"] == nil)
            #expect(json["functions"] == nil)
        }
    }

    @Test func responseDecodingPerKind() throws {
        // OpenAI Responses shape.
        let openAI = #"{"output":[{"content":[{"type":"output_text","text":"hello notes"}]}]}"#
        #expect(try ProviderWire.decodeTranscription(kind: .openAI, body: Data(openAI.utf8)) == "hello notes")
        // Anthropic shape.
        let anthropic = #"{"content":[{"type":"text","text":"line one"},{"type":"text","text":"line two"}]}"#
        #expect(try ProviderWire.decodeTranscription(kind: .anthropic, body: Data(anthropic.utf8)) == "line one\nline two")
        // OpenAI-compatible shape.
        let chat = #"{"choices":[{"message":{"content":"body text"}}]}"#
        #expect(try ProviderWire.decodeTranscription(kind: .openAICompatible, body: Data(chat.utf8)) == "body text")

        // Empty and malformed are NEVER reported as successful empty OCR.
        #expect(throws: WireError.emptyTranscription.self) {
            _ = try ProviderWire.decodeTranscription(kind: .openAI, body: Data(#"{"output":[]}"#.utf8))
        }
        #expect(throws: WireError.self) {
            _ = try ProviderWire.decodeTranscription(kind: .anthropic, body: Data("not json".utf8))
        }
        #expect(throws: WireError.emptyResponse.self) {
            _ = try ProviderWire.decodeTranscription(kind: .openAICompatible, body: Data())
        }
        // Error bodies surface their message.
        #expect(throws: WireError.malformedResponse("provider error: bad model")) {
            _ = try ProviderWire.decodeTranscription(kind: .openAICompatible, body: Data(#"{"error":{"message":"bad model"}}"#.utf8))
        }
    }

    @Test func promptIsTranscriptionInputOnly() {
        // The prompt text never injects tool/system semantics; it asks for a
        // faithful transcription and marks unreadable writing.
        #expect(PromptVersion.text.contains("Transcribe"))
        #expect(PromptVersion.text.contains("[unreadable]"))
        #expect(!PromptVersion.text.lowercased().contains("ignore previous"))
    }
}

@Suite struct EndpointSecurityTests {
    // -- endpointSecurityFixtures -------------------------------------------

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
        // Benign queries are fine.
        #expect(EndpointPolicy.validate(url: URL(string: "https://api.example.com/v1?verbose=true")!) == .allowed)
    }

    @Test func redirectsNeverCrossOriginOrDowngrade() {
        let original = URL(string: "https://api.example.com/v1/chat")!
        #expect(EndpointPolicy.redirectAllowed(from: original, to: URL(string: "https://api.example.com/v2/chat")!))
        #expect(!EndpointPolicy.redirectAllowed(from: original, to: URL(string: "https://evil.example.net/v1")!))
        #expect(!EndpointPolicy.redirectAllowed(from: original, to: URL(string: "http://api.example.com/v1")!))
        // Host is case-insensitive; scheme must be https on the target.
        #expect(EndpointPolicy.redirectAllowed(from: original, to: URL(string: "https://API.Example.Com/v2")!))
    }
}
