import Foundation

/// Reads single entries out of a zip container (PPTX, Keynote packages) with `/usr/bin/unzip`.
struct ZipEntryReader: Sendable {
    let archive: URL

    private static let unzip = URL(fileURLWithPath: "/usr/bin/unzip")

    /// Contents of `entry`, or nil if the archive has no such entry.
    /// - Throws: `ImportError.invalidPresentation` if the file isn't a readable zip.
    func data(for entry: String) throws -> Data? {
        // -p: extract to stdout, -qq: no messages. Entry names are matched as patterns, so escape brackets etc.
        let (status, output, error) = try Self.run(["-p", "-qq", archive.path, Self.escapeGlob(entry)])
        switch status {
        case 0: return output
        case 11: return nil   // "filename not matched"
        default:
            throw ImportError.invalidPresentation(String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func escapeGlob(_ name: String) -> String {
        var escaped = ""
        for character in name {
            if "[]*?\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private static func run(_ arguments: [String]) throws -> (status: Int32, output: Data, error: Data) {
        let process = Process()
        process.executableURL = unzip
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Drain stderr on a background thread so a chatty failure can't fill the pipe and deadlock.
        let errorData = LockedData()
        err.fileHandleForReading.readabilityHandler = { handle in errorData.append(handle.availableData) }
        do { try process.run() } catch {
            throw ImportError.invalidPresentation("unzip is unavailable: \(error.localizedDescription)")
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        errorData.append(err.fileHandleForReading.readDataToEndOfFile())
        return (process.terminationStatus, output, errorData.value)
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()   // guards `data`
    private var data = Data()

    var value: Data { lock.lock(); defer { lock.unlock() }; return data }

    func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
}
