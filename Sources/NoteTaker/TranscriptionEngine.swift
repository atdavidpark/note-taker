import AVFoundation
import Speech

/// Wraps one on-device SpeechAnalyzer + SpeechTranscriber pipeline.
/// The app runs two of these: one for the microphone ("Me") and one for
/// system audio ("Others"). Everything stays on-device.
@available(macOS 26, *)
final class TranscriptionEngine {
    let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(locale: Locale, onModelDownload: @escaping @Sendable (String) -> Void) async throws {
        // Progressive preset streams hypotheses while audio is still playing,
        // instead of buffering everything until the recording stops.
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onModelDownload(L10n.t("Downloading on-device speech model…", "온디바이스 음성 인식 모델 다운로드 중…"))
            try await request.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NoteTakerError.speechModelUnavailable
        }
        analyzerFormat = format

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation
        analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputSequence: stream)
    }

    /// Resolves the transcription locale from the user's preference:
    /// "auto" follows the system language; otherwise a fixed identifier
    /// like "en_US" or "ko_KR". Returns nil when unsupported on-device.
    static func resolveLocale(preference: String) async -> Locale? {
        let requested: Locale = preference == "auto" ? .current : Locale(identifier: preference)
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            return match
        }
        if preference == "auto" {
            return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
        }
        return nil
    }

    /// Called from the capture audio thread. Converts to the analyzer's
    /// preferred format and feeds the analyzer.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        inputContinuation.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async {
        inputContinuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sourceFormat = buffer.format
        if sourceFormat == analyzerFormat { return buffer }
        if converter == nil || converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
        }
        guard let converter else { return nil }
        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: max(capacity, 1)) else {
            return nil
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
