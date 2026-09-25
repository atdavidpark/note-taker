import AVFoundation
import Foundation

/// Thread-safe pause flag shared with the realtime audio callbacks.
final class CaptureGate {
    private let lock = NSLock()
    private var paused = false

    var isPaused: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return paused
        }
        set {
            lock.lock()
            paused = newValue
            lock.unlock()
        }
    }
}

/// Writes captured PCM buffers to an AAC (.m4a) file — roughly 25× smaller
/// than raw WAV at speech-transparent quality. Created on the main thread,
/// written from a single audio thread; the file opens lazily with the first
/// buffer's format and closes on deallocation or `close()`.
final class AudioSink {
    private let url: URL
    private var file: AVAudioFile?
    private var failed = false

    init(url: URL) {
        self.url = url
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard !failed else { return }
        if file == nil {
            let format = buffer.format
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: Int(format.channelCount),
                AVEncoderBitRateKey: 96_000,
            ]
            // Match the file's processing format to the incoming buffers so
            // write(from:) accepts them directly; AVAudioFile encodes to AAC.
            file = try? AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved)
            if file == nil {
                failed = true
                return
            }
        }
        try? file?.write(from: buffer)
    }

    func close() {
        file = nil
    }
}
