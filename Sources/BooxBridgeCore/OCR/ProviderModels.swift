// pattern: Functional Core
// Provider profiles and presets. API keys NEVER live here — profiles
// reference a key stored in the credential store by profile id.

import Foundation

public enum ProviderKind: String, Equatable, Sendable, Codable {
    /// OpenAI Responses API (image input blocks).
    case openAI
    /// Anthropic Messages API (base64 image blocks, version header).
    case anthropic
    /// OpenAI-compatible chat/completions with image_url data URLs —
    /// DeepInfra, Z.ai, and custom endpoints share this adapter.
    case openAICompatible
}

public struct ProviderProfile: Equatable, Sendable, Codable, Identifiable {
    public let id: String
    public var displayName: String
    public var kind: ProviderKind
    public var baseURL: URL
    public var modelID: String
    /// Non-secret OCR options (e.g. detail level); editable, never a key.
    public var detailHint: String?

    public init(id: String = UUID().uuidString,
                displayName: String,
                kind: ProviderKind,
                baseURL: URL,
                modelID: String,
                detailHint: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL
        self.modelID = modelID
        self.detailHint = detailHint
    }
}

public enum ProviderPresets {
    public static let openAI = ProviderProfile(
        displayName: "OpenAI",
        kind: .openAI,
        baseURL: URL(string: "https://api.openai.com/v1")!,
        modelID: "gpt-4o-mini",
        detailHint: "high")

    public static let anthropic = ProviderProfile(
        displayName: "Anthropic",
        kind: .anthropic,
        baseURL: URL(string: "https://api.anthropic.com/v1")!,
        modelID: "claude-sonnet-4-5",
        detailHint: nil)

    public static let deepInfra = ProviderProfile(
        displayName: "DeepInfra",
        kind: .openAICompatible,
        baseURL: URL(string: "https://api.deepinfra.com/v1/openai")!,
        modelID: "meta-llama/Llama-3.2-11B-Vision-Instruct",
        detailHint: nil)

    public static let zai = ProviderProfile(
        displayName: "Z.ai",
        kind: .openAICompatible,
        baseURL: URL(string: "https://api.z.ai/api/paas/v4")!,
        modelID: "glm-4.5v",
        detailHint: nil)

    public static let custom = ProviderProfile(
        displayName: "Custom (OpenAI-compatible)",
        kind: .openAICompatible,
        baseURL: URL(string: "https://example.invalid/v1")!,
        modelID: "",
        detailHint: nil)

    public static let all: [ProviderProfile] = [openAI, anthropic, deepInfra, zai, custom]

    /// Known-good vision model suggestions from provider docs — editable
    /// defaults only. DeepSeek text models are deliberately NOT suggested:
    /// DeepInfra's general vision support does not establish image support
    /// for a user-chosen DeepSeek id; the synthetic capability probe decides.
    public static let suggestedVisionModels: [ProviderKind: [String]] = [
        .openAI: ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini"],
        .anthropic: ["claude-sonnet-4-5", "claude-opus-4-1"],
        .openAICompatible: [
            "meta-llama/Llama-3.2-11B-Vision-Instruct",
            "glm-4.5v",
            "Qwen/Qwen2.5-VL-7B-Instruct",
        ],
    ]
}

/// Capability of an exact (profile, model) pair, recorded by the synthetic
/// image probe. Never assumed from the preset.
public enum ImageCapability: Equatable, Sendable {
    case unknown
    case verified
    case rejected(reason: String)

    public var isUsable: Bool {
        if case .verified = self { return true }
        return false
    }
}

public enum PromptVersion {
    /// Bump when the prompt text changes; queued jobs record the version
    /// they were created for.
    public static let current = 1

    public static var text: String {
        """
        Transcribe the handwritten and printed text on this notebook page image. \
        Copy the text exactly, preserving line breaks and paragraph order. \
        Do not translate, summarize, or add commentary. \
        If a word is unreadable, write [unreadable] in its place. \
        Output only the transcription.
        """
    }
}
