import Foundation

/// The two places where a user can replace a built-in provider with their own endpoint.
/// Both roles use the same credential and endpoint rules, while ASR additionally has a
/// small request-format choice because speech APIs do not share one wire format.
public enum CustomProviderRole: String, Sendable {
    case asr
    case polish
}

public struct CustomProviderConfiguration: Sendable {
    public enum EndpointKind: String, Sendable {
        case chatCompletions
        case audioTranscriptions
    }

    public enum ASRRequestFormat: String, CaseIterable, Sendable {
        /// OpenAI-compatible multipart endpoint: POST /audio/transcriptions.
        case transcriptions
        /// OpenAI-style chat input_audio with raw base64 audio.
        case chatBase64
        /// Qwen/DashScope-style chat input_audio with a data: URL.
        case chatDataURL
    }

    public let endpoint: URL
    public let model: String
    public let apiKey: String
    public let authHeader: String
    public let requestFormat: ASRRequestFormat?
    private let extraBodyData: Data?

    public init?(endpoint: String,
                  model: String,
                  apiKey: String,
                  kind: EndpointKind,
                  authHeader: String? = nil,
                  requestFormat: ASRRequestFormat? = nil,
                  extraBodyJSON: String? = nil) {
        guard let url = Self.resolveEndpoint(endpoint, kind: kind),
              let cleanModel = Self.cleaned(model), !cleanModel.isEmpty else {
            return nil
        }

        let cleanHeader = Self.cleaned(authHeader) ?? "Authorization"
        guard Self.isValidHeaderName(cleanHeader) else { return nil }

        let extraBody = Self.cleaned(extraBodyJSON)
        let extraBodyData: Data?
        if let extraBody, !extraBody.isEmpty {
            guard let data = extraBody.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  object is [String: Any] else {
                return nil
            }
            extraBodyData = data
        } else {
            extraBodyData = nil
        }

        self.endpoint = url
        self.model = cleanModel
        self.apiKey = Self.cleaned(apiKey) ?? ""
        self.authHeader = cleanHeader
        self.requestFormat = requestFormat
        self.extraBodyData = extraBodyData
    }

    /// Accepts either a complete endpoint or an OpenAI-compatible base URL. A base URL
    /// without a path receives the conventional `/v1` prefix; a path such as `/v1` is
    /// preserved and the operation-specific suffix is appended.
    public static func resolveEndpoint(_ rawValue: String, kind: EndpointKind) -> URL? {
        guard var components = URLComponents(string: cleaned(rawValue) ?? "") else {
            return nil
        }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty else {
            return nil
        }

        let suffix: String
        switch kind {
        case .chatCompletions:
            suffix = "/chat/completions"
        case .audioTranscriptions:
            suffix = "/audio/transcriptions"
        }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty {
            path = "/v1" + suffix
        } else if !path.hasSuffix(suffix) {
            path += suffix
        }
        components.path = path
        guard let url = components.url, isTransportAllowed(url: url) else { return nil }
        return url
    }

    public static func authenticationValue(apiKey: String, authHeader: String) -> String? {
        let cleanKey = cleaned(apiKey) ?? ""
        guard !cleanKey.isEmpty else { return nil }
        guard authHeader.caseInsensitiveCompare("Authorization") == .orderedSame else {
            return cleanKey
        }
        return cleanKey.lowercased().hasPrefix("bearer ") ? cleanKey : "Bearer \(cleanKey)"
    }

    public func applyAuthentication(to request: inout URLRequest) {
        guard let value = Self.authenticationValue(apiKey: apiKey, authHeader: authHeader) else { return }
        request.setValue(value, forHTTPHeaderField: authHeader)
    }

    public func extraBody() -> [String: Any] {
        guard let extraBodyData,
              let extra = try? JSONSerialization.jsonObject(with: extraBodyData) as? [String: Any] else {
            return [:]
        }
        return extra
    }

    /// Adds optional provider-specific JSON fields without allowing them to replace
    /// protocol-critical fields such as `model`, `messages`, or `input_audio`.
    public func mergedBody(_ coreBody: [String: Any]) -> [String: Any] {
        var body = extraBody()
        body.merge(coreBody) { _, core in core }
        return body
    }

    public static func load(role: CustomProviderRole, config: VoicePolishConfig) -> CustomProviderConfiguration? {
        let prefix: String
        let requestFormat: ASRRequestFormat?
        switch role {
        case .asr:
            prefix = "custom_asr_"
            let rawFormat = config.string(forKey: "custom_asr_request_format", envKey: environmentKey("custom_asr_request_format"))
            if let rawFormat, let parsed = ASRRequestFormat(rawValue: rawFormat) {
                requestFormat = parsed
            } else if let endpoint = config.string(forKey: "custom_asr_endpoint", envKey: environmentKey("custom_asr_endpoint")),
                      endpoint.lowercased().contains("/chat/completions") {
                // A complete chat endpoint is unambiguous even when an older config omitted request_format.
                requestFormat = .chatDataURL
            } else {
                requestFormat = .transcriptions
            }
        case .polish:
            prefix = "custom_polish_"
            requestFormat = nil
        }

        guard let endpoint = config.string(forKey: prefix + "endpoint", envKey: environmentKey(prefix + "endpoint")),
              let model = config.string(forKey: prefix + "model", envKey: environmentKey(prefix + "model")) else {
            return nil
        }

        let kind: EndpointKind = (role == .asr && requestFormat != .transcriptions)
            ? .chatCompletions
            : (role == .asr ? .audioTranscriptions : .chatCompletions)
        let apiKey = config.string(forKey: prefix + "api_key", envKey: environmentKey(prefix + "api_key")) ?? ""
        let authHeader = config.string(forKey: prefix + "auth_header", envKey: environmentKey(prefix + "auth_header"))
        let extraBodyJSON = config.string(forKey: prefix + "extra_body", envKey: environmentKey(prefix + "extra_body"))

        return CustomProviderConfiguration(
            endpoint: endpoint,
            model: model,
            apiKey: apiKey,
            kind: kind,
            authHeader: authHeader,
            requestFormat: requestFormat,
            extraBodyJSON: extraBodyJSON
        )
    }

    private static func environmentKey(_ suffix: String) -> String {
        let withoutPrefix = suffix.hasPrefix("custom_") ? String(suffix.dropFirst("custom_".count)) : suffix
        return "CUSTOM_" + withoutPrefix.uppercased()
    }

    private static func cleaned(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isTransportAllowed(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http", let host = url.host?.lowercased() else { return false }
        // 明文 HTTP 只给本机回环服务使用；远程明文会把音频和可选凭证暴露给网络。
        return host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
    }

    private static func isValidHeaderName(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "!#$%&'*+-.^_`|~"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
