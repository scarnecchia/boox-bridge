// pattern: Functional Core
// Provider wire codecs. Request encoders and response decoders for the
// three adapter kinds, as pure functions over Codable DTOs. Page content is
// TRANSCRIPTION INPUT ONLY — it is placed in the user message text/image
// blocks, never in instructions/system roles, and no tools are ever sent.

import Foundation

public enum WireError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyResponse
    case malformedResponse(String)
    case responseTooLarge(bytes: Int, limit: Int)
    case emptyTranscription
    case imageFormatUnsupported(String)

    public var description: String {
        switch self {
        case .emptyResponse: return "provider returned an empty response"
        case .malformedResponse(let d): return "provider response was malformed: \(d)"
        case .responseTooLarge(let b, let l): return "provider response was \(b) bytes; limit is \(l)"
        case .emptyTranscription: return "provider returned an empty transcription"
        case .imageFormatUnsupported(let f): return "image format \(f) cannot be sent for transcription"
        }
    }
}

public struct OCRPromptOptions: Sendable {
    public var maxOutputTokens: Int
    public var detail: String?

    public init(maxOutputTokens: Int = 4096, detail: String? = nil) {
        self.maxOutputTokens = maxOutputTokens
        self.detail = detail
    }
}

public struct WireRequest: Equatable, Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data
}

public enum ProviderWire {
    public static let maxResponseBytes = 2 * 1024 * 1024
    public static let syntheticTestPrompt = "Reply with the single word OK."

    /// Build a complete one-page OCR request for a profile.
    /// `imageMediaType` must be a type the target adapter supports.
    public static func makeRequest(
        profile: ProviderProfile,
        apiKey: String,
        prompt: String,
        imagePNGData: Data,
        options: OCRPromptOptions = OCRPromptOptions()
    ) throws -> WireRequest {
        switch profile.kind {
        case .openAI:
            return try openAIResponsesRequest(
                profile: profile, apiKey: apiKey, prompt: prompt,
                imageData: imagePNGData, options: options)
        case .anthropic:
            return try anthropicMessagesRequest(
                profile: profile, apiKey: apiKey, prompt: prompt,
                imageData: imagePNGData, options: options)
        case .openAICompatible:
            return try chatCompletionsRequest(
                profile: profile, apiKey: apiKey, prompt: prompt,
                imageData: imagePNGData, options: options)
        }
    }

    // MARK: - OpenAI Responses API

    struct OpenAIResponsesBody: Codable {
        struct InputItem: Codable {
            let role: String
            let content: [ContentPart]
        }
        struct ContentPart: Codable {
            let type: String
            var text: String?
            var imageURL: String?

            enum CodingKeys: String, CodingKey {
                case type, text
                case imageURL = "image_url"
            }
        }
        let model: String
        let input: [InputItem]
        let maxOutputTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, input
            case maxOutputTokens = "max_output_tokens"
        }
    }

    static func openAIResponsesRequest(
        profile: ProviderProfile, apiKey: String, prompt: String,
        imageData: Data, options: OCRPromptOptions
    ) throws -> WireRequest {
        let body = OpenAIResponsesBody(
            model: profile.modelID,
            input: [.init(role: "user", content: [
                .init(type: "input_text", text: prompt),
                .init(type: "input_image", imageURL: dataURL(png: imageData, detail: options.detail ?? profile.detailHint)),
            ])],
            maxOutputTokens: options.maxOutputTokens)
        return WireRequest(
            url: profile.baseURL.appendingPathComponent("responses"),
            method: "POST",
            headers: authHeaders(apiKey: apiKey, kind: .openAI),
            body: try encoded(body))
    }

    // MARK: - Anthropic Messages API

    struct AnthropicBody: Codable {
        struct ContentPart: Codable {
            let type: String
            var text: String?
            var source: Source?
            struct Source: Codable {
                let type: String
                let mediaType: String
                let data: String
                enum CodingKeys: String, CodingKey {
                    case type, data
                    case mediaType = "media_type"
                }
            }
        }
        struct Message: Codable {
            let role: String
            let content: [ContentPart]
        }
        let model: String
        let maxTokens: Int
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model, messages
            case maxTokens = "max_tokens"
        }
    }

    static func anthropicMessagesRequest(
        profile: ProviderProfile, apiKey: String, prompt: String,
        imageData: Data, options: OCRPromptOptions
    ) throws -> WireRequest {
        let body = AnthropicBody(
            model: profile.modelID,
            maxTokens: options.maxOutputTokens,
            messages: [.init(role: "user", content: [
                .init(type: "image", source: .init(
                    type: "base64", mediaType: "image/png", data: imageData.base64EncodedString())),
                .init(type: "text", text: prompt),
            ])])
        var headers = authHeaders(apiKey: apiKey, kind: .anthropic)
        headers["anthropic-version"] = "2023-06-01"
        return WireRequest(
            url: profile.baseURL.appendingPathComponent("messages"),
            method: "POST",
            headers: headers,
            body: try encoded(body))
    }

    // MARK: - OpenAI-compatible chat/completions

    struct ChatCompletionsBody: Codable {
        struct ImageURL: Codable { let url: String }
        struct ContentPart: Codable {
            let type: String
            var text: String?
            var imageURL: ImageURL?

            enum CodingKeys: String, CodingKey {
                case type, text
                case imageURL = "image_url"
            }
        }
        struct Message: Codable {
            let role: String
            let content: [ContentPart]
        }
        let model: String
        let messages: [Message]
    }

    static func chatCompletionsRequest(
        profile: ProviderProfile, apiKey: String, prompt: String,
        imageData: Data, options: OCRPromptOptions
    ) throws -> WireRequest {
        let body = ChatCompletionsBody(
            model: profile.modelID,
            messages: [.init(role: "user", content: [
                .init(type: "text", text: prompt),
                .init(type: "image_url", imageURL: .init(url: dataURL(png: imageData, detail: options.detail ?? profile.detailHint))),
            ])])
        return WireRequest(
            url: profile.baseURL.appendingPathComponent("chat/completions"),
            method: "POST",
            headers: authHeaders(apiKey: apiKey, kind: .openAICompatible),
            body: try encoded(body))
    }

    // MARK: - Response decoding

    public static func decodeTranscription(
        kind: ProviderKind,
        body: Data
    ) throws -> String {
        guard !body.isEmpty else { throw WireError.emptyResponse }
        guard body.count <= maxResponseBytes else {
            throw WireError.responseTooLarge(bytes: body.count, limit: maxResponseBytes)
        }
        switch kind {
        case .openAI:
            struct Response: Decodable {
                struct OutputItem: Decodable {
                    struct ContentItem: Decodable {
                        let type: String?
                        let text: String?
                    }
                    let content: [ContentItem]?
                }
                let output: [OutputItem]?
                // Error bodies carry a top-level error object.
                let error: ErrorMessage?
                struct ErrorMessage: Decodable {
                    let message: String?
                }
            }
            let decoded = try decode(Response.self, from: body)
            if let message = decoded.error?.message {
                throw WireError.malformedResponse("provider error: \(message)")
            }
            let text = (decoded.output ?? [])
                .compactMap(\.content)
                .flatMap { $0 }
                .filter { $0.type == "output_text" }
                .compactMap(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw WireError.emptyTranscription }
            return text

        case .anthropic:
            struct Response: Decodable {
                struct ContentItem: Decodable {
                    let type: String?
                    let text: String?
                }
                let content: [ContentItem]?
                let error: ErrorMessage?
                struct ErrorMessage: Decodable {
                    struct Detail: Decodable { let message: String? }
                    let message: String?
                    let type: String?
                }
            }
            let decoded = try decode(Response.self, from: body)
            if let error = decoded.error {
                throw WireError.malformedResponse("provider error: \(error.type ?? "error"): \(error.message ?? "")")
            }
            let text = (decoded.content ?? [])
                .filter { $0.type == "text" }
                .compactMap(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw WireError.emptyTranscription }
            return text

        case .openAICompatible:
            struct Response: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable {
                        let content: String?
                    }
                    let message: Message?
                }
                let choices: [Choice]?
                let error: ErrorMessage?
                struct ErrorMessage: Decodable {
                    let message: String?
                }
            }
            let decoded = try decode(Response.self, from: body)
            if let message = decoded.error?.message {
                throw WireError.malformedResponse("provider error: \(message)")
            }
            let text = (decoded.choices ?? [])
                .compactMap(\.message?.content)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw WireError.emptyTranscription }
            return text
        }
    }

    // MARK: - Helpers

    static func dataURL(png imageData: Data, detail: String?) -> String {
        var url = "data:image/png;base64,\(imageData.base64EncodedString())"
        if let detail, !detail.isEmpty {
            url = "data:image/png;detail=\(detail);base64,\(imageData.base64EncodedString())"
        }
        return url
    }

    static func authHeaders(apiKey: String, kind: ProviderKind) -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        switch kind {
        case .anthropic:
            headers["x-api-key"] = apiKey
        default:
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        return headers
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch is DecodingError {
            throw WireError.malformedResponse("body was not the expected JSON shape")
        }
    }
}
