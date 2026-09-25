import AVFoundation
import CoreAudio

/// Captures everything the Mac plays (browser meeting audio included) using a
/// Core Audio process tap (macOS 14.2+). Requires the "System Audio Recording"
/// permission — audio only, no screen recording.
final class SystemAudioRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var format: AVAudioFormat?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var isRunning = false

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.onBuffer = onBuffer

        // 1. Tap on all system audio except our own process.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "NoteTaker System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            throw NoteTakerError.coreAudio("create tap", status)
        }
        tapID = newTapID

        // 2. Read the tap's stream format.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let tapFormat = AVAudioFormat(streamDescription: &asbd) else {
            cleanUp()
            throw NoteTakerError.coreAudio("read tap format", status)
        }
        format = tapFormat

        // 3. Private aggregate device that contains just the tap.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NoteTaker Tap Device",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            cleanUp()
            throw NoteTakerError.coreAudio("create aggregate device", status)
        }
        aggregateID = newAggregateID

        // 4. IO proc copies each buffer off the realtime thread's buffer list.
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inInputData, _, _, _ in
            self?.deliver(bufferList: inInputData)
        }
        guard status == noErr, ioProcID != nil else {
            cleanUp()
            throw NoteTakerError.coreAudio("create IO proc", status)
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanUp()
            throw NoteTakerError.coreAudio("start device", status)
        }
        isRunning = true
    }

    private func deliver(bufferList: UnsafePointer<AudioBufferList>) {
        guard let format, let onBuffer else { return }
        let mutableList = UnsafeMutablePointer(mutating: bufferList)
        guard let source = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: mutableList, deallocator: nil),
              source.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength)
        else { return }
        copy.frameLength = source.frameLength
        // Copy the raw audio buffer list byte-for-byte. This is correct for both
        // interleaved (one buffer holding L/R samples alternately — what taps
        // usually produce) and non-interleaved (one buffer per channel) layouts;
        // a per-channel pointer copy is not.
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(mutableList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return }
        for index in 0..<sourceBuffers.count {
            guard let src = sourceBuffers[index].mData, let dst = destinationBuffers[index].mData else { return }
            let bytes = min(sourceBuffers[index].mDataByteSize, destinationBuffers[index].mDataByteSize)
            memcpy(dst, src, Int(bytes))
            destinationBuffers[index].mDataByteSize = bytes
        }
        onBuffer(copy)
    }

    func stop() {
        guard isRunning || tapID != kAudioObjectUnknown else { return }
        cleanUp()
        isRunning = false
    }

    private func cleanUp() {
        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        onBuffer = nil
    }
}
