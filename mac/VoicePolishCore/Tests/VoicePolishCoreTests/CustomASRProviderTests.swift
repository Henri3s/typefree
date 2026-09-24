import XCTest
@testable import VoicePolishCore

final class CustomASRProviderTests: XCTestCase {

    private func temporaryConfig(_ values: [String: Any]) -> (VoicePolishConfig, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-asr-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = VoicePolishConfig(configDir: directory, secrets: InMemorySecretStore())
        config.save(values: values)
        return (config, directory)
    }

    func testCustomASRVersionIsSynchronousAndHasNoBuiltinFallback() {
        XCTAssertEqual(CloudASRTranscriber.ASRVersion.custom.provider, .custom)
        XCTAssertTrue(CloudASRTranscriber.ASRVersion.custom.isSync)
        XCTAssertNil(CloudASRTranscriber.ASRVersion.custom.nextForFallback)
    }

    func testChatASRConfigurationResolvesChatEndpoint() {
        let (config, directory) = temporaryConfig([
            "custom_asr_endpoint": "https://example.com/v1",
            "custom_asr_model": "audio-model",
            "custom_asr_request_format": "chatDataURL",
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        let loaded = CustomProviderConfiguration.load(role: .asr, config: config)

        XCTAssertEqual(loaded?.endpoint.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(loaded?.requestFormat, .chatDataURL)
    }

    func testFullChatEndpointIsInferredWhenRequestFormatIsMissing() {
        let (config, directory) = temporaryConfig([
            "custom_asr_endpoint": "https://example.com/v1/chat/completions",
            "custom_asr_model": "audio-model",
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        let loaded = CustomProviderConfiguration.load(role: .asr, config: config)

        XCTAssertEqual(loaded?.endpoint.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(loaded?.requestFormat, .chatDataURL)
    }

    func testCustomASRConfigurationIsInjectedAndCanBeSelected() {
        let (config, directory) = temporaryConfig([
            "bigasr_version": "custom",
            "custom_asr_endpoint": "https://example.com/v1",
            "custom_asr_model": "whisper-large",
            "custom_asr_api_key": "secret",
        ])
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcriber = CloudASRTranscriber(config: config)

        XCTAssertEqual(transcriber.currentVersion(), .custom)
        XCTAssertTrue(transcriber.isConfigured(version: .custom))
    }

    func testChatAudioBodySupportsRawBase64AndDataURL() {
        let raw = CloudASRTranscriber.makeCustomChatBody(
            audioData: Data([1, 2, 3]),
            format: "wav",
            model: "audio-model",
            context: "ChatGPT、Typefree",
            dataStyle: .chatBase64
        )
        let dataURL = CloudASRTranscriber.makeCustomChatBody(
            audioData: Data([1, 2, 3]),
            format: "wav",
            model: "audio-model",
            context: nil,
            dataStyle: .chatDataURL
        )

        let rawMessages = raw["messages"] as? [[String: Any]]
        let rawContent = rawMessages?.last?["content"] as? [[String: Any]]
        let rawPart = rawContent?.first
        let rawAudio = rawPart?["input_audio"] as? [String: Any]
        let dataMessages = dataURL["messages"] as? [[String: Any]]
        let dataContent = dataMessages?.last?["content"] as? [[String: Any]]
        let dataPart = dataContent?.first
        let dataURLAudio = dataPart?["input_audio"] as? [String: Any]
        XCTAssertEqual(rawAudio?["data"] as? String, "AQID")
        XCTAssertEqual(rawAudio?["format"] as? String, "wav")
        XCTAssertEqual(dataURLAudio?["data"] as? String, "data:audio/wav;base64,AQID")
        XCTAssertEqual(dataURLAudio?["format"] as? String, "wav")
        XCTAssertEqual((raw["messages"] as? [[String: Any]])?.count, 2)
    }

    func testTranscriptionMultipartBodyContainsModelAndAudio() throws {
        let boundary = "TypefreeTestBoundary"
        let body = try XCTUnwrap(CloudASRTranscriber.makeCustomTranscriptionBody(
            audioData: Data([1, 2, 3]),
            format: "wav",
            model: "whisper-1",
            boundary: boundary,
            context: "Typefree",
            extraFields: ["language": "zh", "response_format": "json"]
        ))
        let string = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertTrue(string.contains("name=\"file\""))
        XCTAssertTrue(string.contains("filename=\"recording.wav\""))
        XCTAssertTrue(string.contains("name=\"model\""))
        XCTAssertTrue(string.contains("whisper-1"))
        XCTAssertTrue(string.contains("name=\"prompt\""))
        XCTAssertTrue(string.contains("Typefree"))
        XCTAssertTrue(string.contains("name=\"language\""))
        XCTAssertTrue(string.contains("zh"))
    }
}
