import Foundation

enum WAVEncoder {
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        precondition(sampleRate > 0, "sampleRate must be positive")

        let bytesPerSample = MemoryLayout<Int16>.size
        let dataByteCount = samples.count * bytesPerSample
        precondition(dataByteCount <= Int(UInt32.max) - 36, "audio payload is too large for WAV")
        let riffChunkSize = 36 + dataByteCount
        let byteRate = sampleRate * bytesPerSample
        precondition(byteRate <= Int(UInt32.max), "byteRate exceeds WAV limits")
        let blockAlign = UInt16(bytesPerSample)

        var data = Data()
        data.reserveCapacity(44 + dataByteCount)

        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(riffChunkSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(byteRate))
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: UInt16(bytesPerSample * 8))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: UInt32(dataByteCount))

        for sample in samples {
            data.append(littleEndian: pcm16Sample(from: sample))
        }

        return data
    }

    private static func pcm16Sample(from sample: Float) -> Int16 {
        let clampedSample = min(max(sample, -1), 1)
        if clampedSample >= 0 {
            return Int16((clampedSample * Float(Int16.max)).rounded())
        }

        return Int16((clampedSample * Float(Int16.max + 1)).rounded())
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(bytes.bindMemory(to: UInt8.self))
        }
    }
}
