import AVFoundation

final class AudioRecorder {
    private let engine = AVAudioEngine()
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

    /// Clears the in-memory audio buffer.
    func resetBuffer() {
        bufferLock.lock()
        audioBuffer = []
        bufferLock.unlock()
    }

    /// Starts capturing audio from the default input device.
    /// Audio is converted to 16 kHz mono Float32 and appended to `audioBuffer`.
    func startRecording() throws {
        resetBuffer()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        print("AudioRecorder: input device format = \(inputFormat), sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputAvailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterCreationFailed
        }

        // Choose a buffer size that gives roughly 100ms of audio at the input sample rate.
        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(inputFormat.sampleRate * 0.1)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] pcmBuffer, _ in
            guard let self = self else { return }
            self.convert(buffer: pcmBuffer, using: converter)
        }

        try engine.start()
    }

    /// Stops capturing audio and returns the recorded buffer.
    /// Waits briefly to flush any remaining audio in the engine's buffer.
    func stopRecording() async -> [Float] {
        // Wait 200ms to let the last audio buffers flush through
        try? await Task.sleep(nanoseconds: 200_000_000)

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        bufferLock.lock()
        let result = audioBuffer
        bufferLock.unlock()
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

        bufferLock.lock()
        audioBuffer.append(contentsOf: frames)
        bufferLock.unlock()
    }
}

// MARK: - Errors

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
