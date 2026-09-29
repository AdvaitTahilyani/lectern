import AVFoundation
import Foundation
import LecternCore
@testable import LecternImport

// MARK: - Paths

enum TestData {
    static let repo = URL(fileURLWithPath: "/Users/advaittahilyani/Lectern")
    static let directory = repo.appendingPathComponent("TestData")
    static let savedPage = URL(fileURLWithPath: "/Users/advaittahilyani/Downloads/extracted.html")
    static let captions = directory.appendingPathComponent("cs426-captions.vtt")
    static let manifestURLs = directory.appendingPathComponent("1_oj3ppr67.url")

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static var live: Bool { ProcessInfo.processInfo.environment["LECTERN_LIVE_TESTS"] == "1" }
}

func makeTemporaryDirectory(_ name: String = "test") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lectern-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Tools

/// Synthesizes speech with the system `say` and converts it with `afconvert`.
enum SpeechFixture {
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/say") && FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert")
    }

    /// `format`: "m4a", "aiff", "wav", "adts" (raw AAC), "mp4" (AAC in MP4).
    static func make(_ text: String, format: String, in directory: URL) throws -> URL {
        let aiff = directory.appendingPathComponent("speech-\(UUID().uuidString).aiff")
        try run("/usr/bin/say", ["-o", aiff.path, text])
        if format == "aiff" { return aiff }
        let out = directory.appendingPathComponent("speech-\(UUID().uuidString).\(format == "adts" ? "aac" : format)")
        switch format {
        case "wav": try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@22050", aiff.path, out.path])
        case "m4a": try run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", aiff.path, out.path])
        case "mp4": try run("/usr/bin/afconvert", ["-f", "mp4f", "-d", "aac", aiff.path, out.path])
        case "adts": try run("/usr/bin/afconvert", ["-f", "adts", "-d", "aac", aiff.path, out.path])
        default: fatalError("unknown format")
        }
        return out
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

// MARK: - HTTP stub

struct StubResponse {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()

    static func text(_ string: String, status: Int = 200) -> StubResponse { StubResponse(status: status, body: Data(string.utf8)) }
    static func data(_ data: Data) -> StubResponse { StubResponse(body: data) }
    static let notFound = StubResponse(status: 404)
}

/// An in-process HTTP server for `URLSession`: routes are a closure over the request URL.
final class StubServer: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: StubServer] = [:]

    let id = UUID().uuidString
    private let lock = NSLock()   // guards `seen`
    private var seen: [URL] = []
    private let route: @Sendable (URL) -> StubResponse

    init(route: @escaping @Sendable (URL) -> StubResponse) {
        self.route = route
        Self.registryLock.lock(); Self.registry[id] = self; Self.registryLock.unlock()
    }

    deinit {
        Self.registryLock.lock(); Self.registry[id] = nil; Self.registryLock.unlock()
    }

    var requests: [URL] { lock.lock(); defer { lock.unlock() }; return seen }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Stub-ID": id]
        return URLSession(configuration: configuration)
    }

    fileprivate static func server(for request: URLRequest) -> StubServer? {
        registryLock.lock(); defer { registryLock.unlock() }
        return request.value(forHTTPHeaderField: "X-Stub-ID").flatMap { registry[$0] }
    }

    fileprivate func respond(to url: URL) -> StubResponse {
        lock.lock(); seen.append(url); lock.unlock()
        return route(url)
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = StubServer.server(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let stub = server.respond(to: url)
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - MPEG-TS synthesis

enum TSBuilder {
    /// An ADTS frame (AAC-LC, 16 kHz, mono) around arbitrary payload bytes.
    static func adtsFrame(payload: [UInt8]) -> Data {
        let length = payload.count + 7
        var frame: [UInt8] = [
            0xFF, 0xF1,
            (1 << 6) | (8 << 2) | 0,             // AAC-LC, 16 kHz, channel config high bit
            (1 << 6) | UInt8((length >> 11) & 0x3),  // channel config low bits + length high bits
            UInt8((length >> 3) & 0xFF),
            UInt8((length & 0x7) << 5) | 0x1F,
            0xFC,
        ]
        frame += payload
        return Data(frame)
    }

    /// A transport-stream segment carrying a video stream (ignored) and an audio stream.
    /// - Parameter chunks: each element becomes one audio PES packet.
    static func segment(audioChunks chunks: [Data], streamType: UInt8 = 0x0F) -> Data {
        var packets = Data()
        var continuity: [Int: UInt8] = [:]

        func packet(pid: Int, unitStart: Bool, payload: Data) -> Data {
            var p = Data([0x47, (unitStart ? 0x40 : 0) | UInt8(pid >> 8), UInt8(pid & 0xFF)])
            let counter = continuity[pid, default: 0]
            continuity[pid] = (counter + 1) & 0xF
            let room = 184
            if payload.count >= room {
                p.append(0x10 | counter)
                p.append(payload.prefix(room))
            } else {
                // Pad with an adaptation field of stuffing bytes.
                p.append(0x30 | counter)
                let stuffing = room - payload.count - 1
                p.append(UInt8(stuffing))
                if stuffing > 0 {
                    p.append(0x00)
                    p.append(Data(repeating: 0xFF, count: stuffing - 1))
                }
                p.append(payload)
            }
            return p
        }

        func psi(pid: Int, table: [UInt8]) -> Data {
            packet(pid: pid, unitStart: true, payload: Data([0x00] + table + Array(repeating: 0xFF, count: 0)))
        }

        // PAT: program 1 → PMT PID 0x1000.
        let pat: [UInt8] = [0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xF0, 0x00, 0, 0, 0, 0]
        packets.append(psi(pid: 0, table: pat))
        // PMT: video H.264 on 0x100, audio on 0x101.
        let pmtBody: [UInt8] = [
            0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x00, 0xF0, 0x00,
            0x1B, 0xE1, 0x00, 0xF0, 0x00,
            streamType, 0xE1, 0x01, 0xF0, 0x00,
            0, 0, 0, 0,
        ]
        let pmt: [UInt8] = [0x02, 0xB0, UInt8(pmtBody.count)] + pmtBody
        packets.append(psi(pid: 0x1000, table: pmt))

        // Some video noise that must be skipped.
        packets.append(packet(pid: 0x100, unitStart: true, payload: Data([0, 0, 1, 0xE0, 0, 0, 0x80, 0, 0] + Array(repeating: 0xAB, count: 50))))

        for chunk in chunks {
            let pes = Data([0, 0, 1, 0xC0, 0, 0, 0x80, 0x80, 0x05, 0x21, 0, 1, 0, 1]) + chunk
            var offset = 0
            var first = true
            while offset < pes.count {
                let end = min(offset + 184, pes.count)
                packets.append(packet(pid: 0x101, unitStart: first, payload: pes[offset..<end]))
                first = false
                offset = end
            }
        }
        return packets
    }
}
