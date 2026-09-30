import Foundation

/// Pulls the audio elementary stream out of an MPEG transport stream segment (what Kaltura's HLS
/// serves). AVFoundation can't open `.ts` files, but it does read raw ADTS AAC and MP3 streams, so
/// the result is written out as `.aac` / `.mp3` and handed to `AudioExtractor`.
enum MPEGTSAudioDemuxer {
    enum Codec: Sendable, Equatable {
        /// AAC in ADTS framing (stream type 0x0F); every frame carries its own header.
        case aacADTS
        /// MPEG-1/2 audio layer III (stream types 0x03/0x04).
        case mp3

        var fileExtension: String {
            switch self {
            case .aacADTS: "aac"
            case .mp3: "mp3"
            }
        }
    }

    struct Audio: Sendable {
        var codec: Codec
        var data: Data
    }

    private static let packetSize = 188
    private static let syncByte: UInt8 = 0x47

    /// Extracts the first audio stream of one segment.
    /// - Throws: `ImportError.unsupportedStream` for missing tables or unsupported codecs
    ///   (AC-3, AAC-LATM…), `ImportError.malformedResponse` if the data isn't a transport stream.
    static func extractAudio(from segment: Data) throws -> Audio {
        guard segment.count >= packetSize, segment.first == syncByte else {
            throw ImportError.malformedResponse("segment is not an MPEG transport stream")
        }
        var pmtPID: Int?
        var audioPID: Int?
        var codec: Codec?
        var elementary = Data()

        segment.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            var lastSync = 0
            while offset + packetSize <= bytes.count {
                guard bytes[offset] == syncByte else {
                    // A lost or extra byte shifted the packet grid: look for the next run of aligned sync
                    // bytes just after the last good packet, rather than skipping the rest of the segment.
                    offset = resynchronized(in: bytes, after: lastSync)
                    continue
                }
                lastSync = offset
                defer { offset += packetSize }
                let startsUnit = bytes[offset + 1] & 0x40 != 0
                let pid = (Int(bytes[offset + 1] & 0x1F) << 8) | Int(bytes[offset + 2])
                let adaptation = (bytes[offset + 3] >> 4) & 0x3
                guard adaptation & 0x1 != 0 else { continue }   // no payload
                var payloadStart = offset + 4
                if adaptation & 0x2 != 0 { payloadStart += 1 + Int(bytes[offset + 4]) }
                let payloadEnd = offset + packetSize
                guard payloadStart < payloadEnd else { continue }
                let payload = UnsafeRawBufferPointer(rebasing: bytes[payloadStart..<payloadEnd])

                if pid == 0, pmtPID == nil {
                    pmtPID = programMapPID(inPAT: payload, startsUnit: startsUnit)
                } else if pid == pmtPID, audioPID == nil {
                    (audioPID, codec) = audioStream(inPMT: payload, startsUnit: startsUnit)
                } else if pid == audioPID {
                    if startsUnit {
                        // PES header: 00 00 01 sid len(2) flags(2) headerLength, then the payload.
                        guard payload.count >= 9, payload[0] == 0, payload[1] == 0, payload[2] == 1 else { continue }
                        let dataStart = 9 + Int(payload[8])
                        if dataStart < payload.count { elementary.append(contentsOf: payload[dataStart...]) }
                    } else {
                        elementary.append(contentsOf: payload)
                    }
                }
            }
        }

        guard let codec else {
            throw ImportError.unsupportedStream(audioPID == nil && pmtPID != nil ? "no supported audio stream in the segment" : "segment has no program tables")
        }
        switch codec {
        case .aacADTS: return Audio(codec: codec, data: adtsFrames(in: elementary))
        case .mp3: return Audio(codec: codec, data: elementary)
        }
    }

    /// Offset of the first packet start after `lastSync` that is confirmed by sync bytes at the next
    /// packet positions (as many as fit), or the end of the data if there is none.
    private static func resynchronized(in bytes: UnsafeRawBufferPointer, after lastSync: Int) -> Int {
        var candidate = lastSync + 1
        while candidate + packetSize <= bytes.count {
            if bytes[candidate] == syncByte,
               (1...2).allSatisfy({ candidate + $0 * packetSize >= bytes.count || bytes[candidate + $0 * packetSize] == syncByte })
            {
                return candidate
            }
            candidate += 1
        }
        return bytes.count
    }

    // MARK: - Program tables

    /// Payload of a PSI packet after the pointer field, starting at the table id.
    private static func section(_ payload: UnsafeRawBufferPointer, startsUnit: Bool) -> UnsafeRawBufferPointer? {
        guard startsUnit, payload.count > 1 else { return nil }
        let start = 1 + Int(payload[0])
        guard start < payload.count else { return nil }
        return UnsafeRawBufferPointer(rebasing: payload[start...])
    }

    private static func programMapPID(inPAT payload: UnsafeRawBufferPointer, startsUnit: Bool) -> Int? {
        guard let table = section(payload, startsUnit: startsUnit), table.count >= 12, table[0] == 0x00 else { return nil }
        let length = (Int(table[1] & 0x0F) << 8) | Int(table[2])
        let end = min(table.count, 3 + length - 4)   // exclude CRC
        var index = 8
        while index + 4 <= end {
            let program = (Int(table[index]) << 8) | Int(table[index + 1])
            let pid = (Int(table[index + 2] & 0x1F) << 8) | Int(table[index + 3])
            if program != 0 { return pid }
            index += 4
        }
        return nil
    }

    private static func audioStream(inPMT payload: UnsafeRawBufferPointer, startsUnit: Bool) -> (Int?, Codec?) {
        guard let table = section(payload, startsUnit: startsUnit), table.count >= 16, table[0] == 0x02 else { return (nil, nil) }
        let length = (Int(table[1] & 0x0F) << 8) | Int(table[2])
        let end = min(table.count, 3 + length - 4)
        let programInfoLength = (Int(table[10] & 0x0F) << 8) | Int(table[11])
        var index = 12 + programInfoLength
        while index + 5 <= end {
            let streamType = table[index]
            let pid = (Int(table[index + 1] & 0x1F) << 8) | Int(table[index + 2])
            let infoLength = (Int(table[index + 3] & 0x0F) << 8) | Int(table[index + 4])
            switch streamType {
            case 0x0F: return (pid, .aacADTS)
            case 0x03, 0x04: return (pid, .mp3)
            default: break
            }
            index += 5 + infoLength
        }
        return (nil, nil)
    }

    // MARK: - ADTS

    /// Keeps only complete, back-to-back ADTS frames, discarding a truncated frame at either end
    /// (a PES packet can straddle a segment boundary) and resynchronizing after corrupt bytes.
    static func adtsFrames(in stream: Data) -> Data {
        var output = Data()
        stream.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            while index + 7 <= bytes.count {
                guard let length = frameLength(at: index, in: bytes) else {
                    index += 1
                    continue
                }
                let next = index + length
                guard next <= bytes.count else { break }
                // A real frame is followed by another frame header (or the end of the data).
                if next + 7 <= bytes.count, frameLength(at: next, in: bytes) == nil {
                    index += 1
                    continue
                }
                output.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[index..<next]))
                index = next
            }
        }
        return output
    }

    private static func frameLength(at index: Int, in bytes: UnsafeRawBufferPointer) -> Int? {
        guard index + 7 <= bytes.count, bytes[index] == 0xFF, bytes[index + 1] & 0xF6 == 0xF0 else { return nil }
        let length = (Int(bytes[index + 3] & 0x03) << 11) | (Int(bytes[index + 4]) << 3) | (Int(bytes[index + 5]) >> 5)
        let headerSize = bytes[index + 1] & 0x01 == 0 ? 9 : 7   // protection_absent == 0 → CRC present
        return length >= headerSize ? length : nil
    }
}
