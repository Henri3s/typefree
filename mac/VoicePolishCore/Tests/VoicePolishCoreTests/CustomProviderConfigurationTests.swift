import XCTest
@testable import VoicePolishCore

final class CustomProviderConfigurationTests: XCTestCase {

    private func temporaryConfig(_ values: [String: Any] = [:]) -> (VoicePolishConfig, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-provider-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = VoicePolishConfig(configDir: directory, secrets: InMemorySecretStore())
        if !values.isEmpty { config.save(values: values) }
        return (config, directory)
    }

    func testResolvesChatEndpointFromBaseURLAndKeepsFullEndpoint() {
        let root = CustomProviderConfiguration.resolveEndpoint(
            "https://example.com",
            kind: .chatCompletions
        )
        let base = CustomProviderConfiguration.resolveEndpoint(
            "https://example.com/v1/",
            kind: .chatCompletions
        )
        let full = CustomProviderConfiguration.resolveEndpoint(
            "https://example.com/v1/chat/completions?api-version=2026-01-01",
            kind: .chatCompletions
        )

        XCTAssertEqual(root?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(base?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(full?.absoluteString, "https://example.com/v1/chat/completions?api-version=2026-01-01")
    }

    func testResolvesAudioTranscriptionEndpoint() {
        let endpoint = CustomProviderConfiguration.resolveEndpoint(
            "https://example.com/v1",
            kind: .audioTranscriptions
        )

        XCTAssertEqual(endpoint?.absoluteString, "https://example.com/v1/audio/transcriptions")
    }

    func testCustomPolishConfigurationLoadsSecretAndAuthDefaults() {
        let (config, directory) = temporaryConfig([
            "custom_polish_endpoint": "https://example.com/v1",
            "custom_polish_model": "custom-model",
            "custom_polish_api_key": "secret-key",
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        let loaded = CustomProviderConfiguration.load(role: .polish, config: config)

        XCTAssertEqual(loaded?.endpoint.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(loaded?.model, "custom-model")
        XCTAssertEqual(loaded?.apiKey, "secret-key")
        XCTAssertEqual(loaded?.authHeader, "Authorization")
    }

    func testCustomConfigurationAllowsEmptyKeyForLocalServer() {
        let (config, directory) = temporaryConfig([
            "custom_asr_endpoint": "http://127.0.0.1:11434/v1",
            "custom_asr_model": "local-whisper",
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        let loaded = CustomProviderConfiguration.load(role: .asr, config: config)

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.apiKey, "")
    }

    func testCustomHeaderUsesRawKeyAndBearerAuthorizationUsesPrefix() {
        let bearer = CustomProviderConfiguration(
            endpoint: "https://example.com/v1",
            model: "model",
            apiKey: "key",
            kind: .chatCompletions
        )
        let header = CustomProviderConfiguration(
            endpoint: "https://example.com/v1",
            model: "model",
            apiKey: "key",
            kind: .chatCompletions,
            authHeader: "X-API-Key"
        )

        var bearerRequest = URLRequest(url: URL(string: "https://example.com")!)
        bearer?.applyAuthentication(to: &bearerRequest)
        var headerRequest = URLRequest(url: URL(string: "https://example.com")!)
        header?.applyAuthentication(to: &headerRequest)

        XCTAssertEqual(bearerRequest.value(forHTTPHeaderField: "Authorization"), "Bearer key")
        XCTAssertEqual(headerRequest.value(forHTTPHeaderField: "X-API-Key"), "key")
    }

    func testBearerPrefixIsNotDuplicated() {
        XCTAssertEqual(CustomProviderConfiguration.authenticationValue(apiKey: "Bearer key", authHeader: "Authorization"), "Bearer key")
        XCTAssertEqual(CustomProviderConfiguration.authenticationValue(apiKey: " key ", authHeader: "X-API-Key"), "key")
        XCTAssertNil(CustomProviderConfiguration.authenticationValue(apiKey: "", authHeader: "Authorization"))
    }

    func testExtraBodyJSONIsMergedWithoutReplacingCoreFields() {
        let custom = CustomProviderConfiguration(
            endpoint: "https://example.com/v1",
            model: "model",
            apiKey: "key",
            kind: .chatCompletions,
            extraBodyJSON: #"{"temperature":0.2,"model":"must-not-replace"}"#
        )

        let body = custom?.mergedBody([
            "model": "core-model",
            "messages": [["role": "user", "content": "hello"]],
        ])

        XCTAssertEqual(body?["temperature"] as? Double, 0.2)
        XCTAssertEqual(body?["model"] as? String, "core-model")
        XCTAssertEqual((body?["messages"] as? [[String: String]])?.first?["content"], "hello")
    }

    func testCustomAPIKeysAreStoredOnlyInSecretStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-provider-secrets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = InMemorySecretStore()
        let config = VoicePolishConfig(configDir: directory, secrets: secrets)

        config.save(values: [
            "custom_asr_api_key": "asr-secret",
            "custom_polish_api_key": "polish-secret",
            "custom_polish_model": "model",
        ])

        XCTAssertEqual(secrets.get("custom_asr_api_key"), "asr-secret")
        XCTAssertEqual(secrets.get("custom_polish_api_key"), "polish-secret")
        let raw = try String(contentsOf: directory.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("asr-secret"))
        XCTAssertFalse(raw.contains("polish-secret"))
    }

    func testCustomPlaintextKeyIsMigratedToSecretStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-provider-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rawConfig = #"{"custom_polish_api_key":"old-secret","custom_polish_model":"model"}"#
        try rawConfig.write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let secrets = InMemorySecretStore()
        let config = VoicePolishConfig(configDir: directory, secrets: secrets)

        config.reconcileSecrets()

        XCTAssertEqual(secrets.get("custom_polish_api_key"), "old-secret")
        let migrated = try String(contentsOf: directory.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertFalse(migrated.contains("old-secret"))
    }

    func testRemotePlaintextHTTPIsRejected() {
        XCTAssertNil(CustomProviderConfiguration(
            endpoint: "http://example.com/v1",
            model: "model",
            apiKey: "secret",
            kind: .chatCompletions
        ))
        XCTAssertNotNil(CustomProviderConfiguration(
            endpoint: "http://127.0.0.1:11434/v1",
            model: "model",
            apiKey: "",
            kind: .chatCompletions
        ))
    }

    func testInvalidCustomEndpointOrModelIsNotLoadable() {
        let (config, directory) = temporaryConfig([
            "custom_polish_endpoint": "not-a-url",
            "custom_polish_model": "model",
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(CustomProviderConfiguration.load(role: .polish, config: config))
    }
}
