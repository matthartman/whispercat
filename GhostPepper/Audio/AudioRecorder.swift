import AVFoundation
import AudioToolbox
import CoreAudio

final class AudioRecorder {
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?
    var onConvertedAudioChunk: (([Float]) -> Void)?

    /// When set, the recorder targets this specific device instead of the system
    /// default. This is required for aggregate devices created in Audio MIDI Setup.
    var selectedInputDeviceID: AudioDeviceID?

    /// Recreated for every recording session. AVAudioEngine does not reliably
    /// recover when the default input device or its sample rate changes between
    /// sessions (Bluetooth mics flipping between HFP/A2DP profiles is the common
    /// trigger), and the symptom is `HALB_IOThread: there already is a thread`
    /// + EAGAIN on the next start. A fresh instance per session avoids that.
    private var engine = AVAudioEngine()
    private let bufferLock = NSLock()

    /// The accumulated audio samples captured during recording.
    /// Accessible for reading within the module (internal) so tests can inspect it.
    var audioBuffer: [Float] = []

    /// Target format for WhisperKit: 16 kHz, mono, Float32.
    private lazy var targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }()

    /// Pre-warm the audio engine so the first recording starts faster.
    func prewarm() {
        _ = engine.inputNode // Force node initialization
        engine.prepare()
    }

    /// Reset the audio engine to pick up a new default input device.
    /// Call this after changing the system default input device in Settings.
    func resetForDeviceChange() {
        engine.stop()
        engine.reset()
        prewarm()
    }

    static func serializeAudioBuffer(_ samples: [Float]) throws -> Data {
        samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    static func serializePlayableArchiveAudioBuffer(_ samples: [Float]) throws -> Data {
        let sampleRate = UInt32(16_000)
        let channelCount = UInt16(1)
        let bitsPerSample = UInt16(16)
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataSize = samples.count * bytesPerSample
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample) / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let riffChunkSize = UInt32(36 + dataSize)

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(contentsOf: riffChunkSize.littleEndianBytes)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(contentsOf: UInt32(16).littleEndianBytes)
        data.append(contentsOf: UInt16(1).littleEndianBytes)
        data.append(contentsOf: channelCount.littleEndianBytes)
        data.append(contentsOf: sampleRate.littleEndianBytes)
        data.append(contentsOf: byteRate.littleEndianBytes)
        data.append(contentsOf: blockAlign.littleEndianBytes)
        data.append(contentsOf: bitsPerSample.littleEndianBytes)
        data.append("data".data(using: .ascii)!)
        data.append(contentsOf: UInt32(dataSize).littleEndianBytes)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = Int16((clamped * Float(Int16.max)).rounded())
            data.append(contentsOf: scaled.littleEndianBytes)
        }

        return data
    }

    static func deserializeAudioBuffer(from data: Data) throws -> [Float] {
        let stride = MemoryLayout<Float>.stride
        guard data.count.isMultiple(of: stride) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        return data.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            return Array(floatBuffer)
        }
    }

    static func deserializeArchivedAudioBuffer(from data: Data) throws -> [Float] {
        if data.starts(with: Data("RIFF".utf8)) {
            return try deserializeWAVAudioBuffer(from: data)
        }

        return try deserializeAudioBuffer(from: data)
    }

    /// Clears the in-memory audio buffer.
    func resetBuffer() {
        bufferLock.lock()
        audioBuffer = []
        bufferLock.unlock()
    }

    /// Snapshot the buffer under the lock from a sync context.
    /// Extracted so async callers don't touch NSLock directly (Swift 6 enforcement).
    private func snapshotBuffer() -> [Float] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return audioBuffer
    }

    /// Starts capturing audio from the default input device.
    /// Audio is converted to 16 kHz mono Float32 and appended to `audioBuffer`.
    func startRecording() throws {
        resetBuffer()

        // Tear down any leftover state from the previous session and rebuild the
        // engine from scratch. See the engine property's doc comment for why.
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine = AVAudioEngine()

        let inputNode = engine.inputNode

        // Target a specific device (e.g. an aggregate device from Audio MIDI Setup)
        // instead of relying on the system default. The device must be set on the
        // audio unit BEFORE the engine is prepared/started so the engine configures
        // its internal graph for the correct device.
        if let deviceID = selectedInputDeviceID {
            if let audioUnit = inputNode.audioUnit {
                var id = deviceID
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &id,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status != noErr {
                    print("AudioRecorder: failed to set input device \(deviceID), status=\(status)")
                }

                // Re-initialize the audio unit so it picks up the new device's
                // stream configuration (channel count, sample rate, etc.)
                AudioUnitUninitialize(audioUnit)
                AudioUnitInitialize(audioUnit)
            }
        }

        // `inputFormat(forBus:)` reflects the bus's *actual* HW input format.
        // `outputFormat(forBus:)` is the downstream format and is the one that
        // can go stale. Always trust inputFormat for input nodes.
        let hwFormat = inputNode.inputFormat(forBus: 0)
        print("AudioRecorder: input HW format = \(hwFormat), sampleRate=\(hwFormat.sampleRate), channels=\(hwFormat.channelCount)")

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputAvailable
        }

        // Roughly 100ms of audio at the actual HW rate.
        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(hwFormat.sampleRate * 0.1)

        cachedConverter = nil
        cachedConverterSourceFormat = nil

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] pcmBuffer, _ in
            guard let self = self else { return }

            // Aggregate devices can have non-standard channel counts (e.g. 5ch)
            // that AVAudioConverter can't downmix to mono. Manually mix to mono first.
            let buffer: AVAudioPCMBuffer
            if pcmBuffer.format.channelCount > 2 {
                buffer = Self.downmixToMono(pcmBuffer)
            } else {
                buffer = pcmBuffer
            }

            guard let converter = self.converter(for: buffer.format) else { return }
            self.convert(buffer: buffer, using: converter)
        }

        try engine.start()
        onRecordingStarted?()
    }

    private var cachedConverter: AVAudioConverter?
    private var cachedConverterSourceFormat: AVAudioFormat?

    private func converter(for sourceFormat: AVAudioFormat) -> AVAudioConverter? {
        if let cachedConverter, let cachedConverterSourceFormat,
           cachedConverterSourceFormat.sampleRate == sourceFormat.sampleRate,
           cachedConverterSourceFormat.channelCount == sourceFormat.channelCount {
            return cachedConverter
        }

        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        cachedConverter = converter
        cachedConverterSourceFormat = sourceFormat
        if converter == nil {
            print("AudioRecorder: failed to create converter from \(sourceFormat) to \(targetFormat)")
        }
        return converter
    }

    /// Stops capturing audio and returns the recorded buffer.
    /// Waits briefly to flush any remaining audio in the engine's buffer.
    func stopRecording() async -> [Float] {
        // Wait 200ms to let the last audio buffers flush through
        try? await Task.sleep(nanoseconds: 200_000_000)

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onRecordingStopped?()

        let result = snapshotBuffer()
        print("AudioRecorder: stopped, buffer has \(result.count) samples (\(Double(result.count) / 16000.0)s of audio)")
        if !result.isEmpty {
            let maxAmplitude = result.map { abs($0) }.max() ?? 0
            print("AudioRecorder: max amplitude = \(maxAmplitude)")
        }
        return result
    }

    // MARK: - Private

    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (targetFormat.sampleRate / buffer.format.sampleRate)
        ) + 1 // +1 to avoid rounding down to zero

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return
        }

        var error: NSError?
        var allConsumed = false

        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if allConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            allConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            print("AudioRecorder: conversion error – \(error.localizedDescription)")
            return
        }

        guard let channelData = convertedBuffer.floatChannelData, convertedBuffer.frameLength > 0 else {
            return
        }

        let frames = Array(UnsafeBufferPointer(start: channelData[0], count: Int(convertedBuffer.frameLength)))

        appendConvertedFrames(frames)
    }

    /// Downmix a multi-channel PCM buffer to mono by averaging all channels.
    /// Needed for aggregate devices that expose non-standard channel counts
    /// (e.g. 5 channels) which AVAudioConverter cannot downmix.
    private static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let channelData = buffer.floatChannelData else { return buffer }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)

        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameCapacity),
              let monoData = monoBuffer.floatChannelData else {
            return buffer
        }
        monoBuffer.frameLength = buffer.frameLength

        // Pick the loudest channel at each sample rather than averaging.
        // Averaging divides by channel count which dilutes the signal.
        // Max-channel selection preserves the strongest mic's amplitude
        // and gives better SNR (closest mic to the speaker wins).
        for frame in 0..<frameCount {
            var best: Float = 0
            for ch in 0..<channelCount {
                let sample = channelData[ch][frame]
                if abs(sample) > abs(best) {
                    best = sample
                }
            }
            monoData[0][frame] = best
        }

        return monoBuffer
    }

    #if DEBUG
    func test_convert(samples: [Float]) {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat),
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?.pointee {
            for (index, sample) in samples.enumerated() {
                channelData[index] = sample
            }
        }

        convert(buffer: buffer, using: converter)
    }
    #endif

    private func appendConvertedFrames(_ frames: [Float]) {
        bufferLock.lock()
        audioBuffer.append(contentsOf: frames)
        bufferLock.unlock()

        onConvertedAudioChunk?(frames)
    }
}

// MARK: - Errors

private extension AudioRecorder {
    static func deserializeWAVAudioBuffer(from data: Data) throws -> [Float] {
        guard data.count >= 44,
              data.starts(with: Data("RIFF".utf8)),
              data.dropFirst(8).starts(with: Data("WAVE".utf8)) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        var offset = 12
        var audioFormat: UInt16?
        var bitsPerSample: UInt16?
        var channelCount: UInt16?
        var sampleData = Data()

        while offset + 8 <= data.count {
            let chunkIDData = data[offset..<(offset + 4)]
            let chunkSize = UInt32(littleEndian: data[(offset + 4)..<(offset + 8)].withUnsafeBytes { $0.load(as: UInt32.self) })
            offset += 8

            guard offset + Int(chunkSize) <= data.count else {
                throw AudioRecorderPersistenceError.invalidSerializedAudioData
            }

            let chunkData = data[offset..<(offset + Int(chunkSize))]
            let chunkID = String(decoding: chunkIDData, as: UTF8.self)

            if chunkID == "fmt " {
                guard chunkData.count >= 16 else {
                    throw AudioRecorderPersistenceError.invalidSerializedAudioData
                }

                audioFormat = UInt16(littleEndian: chunkData[chunkData.startIndex..<(chunkData.startIndex + 2)].withUnsafeBytes { $0.load(as: UInt16.self) })
                channelCount = UInt16(littleEndian: chunkData[(chunkData.startIndex + 2)..<(chunkData.startIndex + 4)].withUnsafeBytes { $0.load(as: UInt16.self) })
                bitsPerSample = UInt16(littleEndian: chunkData[(chunkData.startIndex + 14)..<(chunkData.startIndex + 16)].withUnsafeBytes { $0.load(as: UInt16.self) })
            } else if chunkID == "data" {
                sampleData = Data(chunkData)
            }

            offset += Int(chunkSize)
            if chunkSize.isMultiple(of: 2) == false {
                offset += 1
            }
        }

        guard audioFormat == 1,
              channelCount == 1,
              bitsPerSample == 16,
              sampleData.count.isMultiple(of: 2) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        return sampleData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            return int16Buffer.map { Float($0) / Float(Int16.max) }
        }
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}

enum AudioRecorderError: Error, LocalizedError {
    case noInputAvailable
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .noInputAvailable:
            return "No audio input device available."
        case .converterCreationFailed:
            return "Failed to create audio format converter."
        }
    }
}

enum AudioRecorderPersistenceError: Error {
    case invalidSerializedAudioData
}
