import Foundation

/// Runs AppleScript source and returns its result text. Abstracted so tests can capture the
/// generated scripts without driving real applications.
protocol AppleScriptRunning: Sendable {
    /// - Parameters:
    ///   - script: AppleScript source containing an `on run argv` handler.
    ///   - arguments: passed to the handler as `argv` (no quoting or escaping needed).
    ///   - application: display name used in error messages.
    ///   - timeout: seconds before the script is killed.
    func run(_ script: String, arguments: [String], application: String, timeout: TimeInterval) async throws -> String
}

/// Executes scripts through `/usr/bin/osascript`, so a hung application can be abandoned by
/// killing the process (which `NSAppleScript` cannot do).
struct OsaScriptRunner: AppleScriptRunning {
    func run(_ script: String, arguments: [String], application: String, timeout: TimeInterval) async throws -> String {
        let job = OsaScriptJob(script: script, arguments: arguments)
        let outcome = try await withTaskCancellationHandler {
            try await job.run(timeout: timeout)
        } onCancel: {
            job.terminate()
        }
        if outcome.timedOut { throw ImportError.conversionTimedOut(app: application) }
        guard outcome.status == 0 else { throw Self.error(from: outcome.stderr, application: application) }
        return outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Maps osascript's stderr (`… (-1743)`) to a user-facing error.
    static func error(from stderr: String, application: String) -> ImportError {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        // -1743: errAEEventNotPermitted — the user denied (or hasn't granted) Automation access.
        if message.contains("(-1743)") { return .automationDenied(app: application) }
        // -128: user canceled; -600: application isn't running / couldn't launch.
        return .conversionFailed(app: application, message: message.isEmpty ? "unknown error" : message)
    }
}

private final class OsaScriptJob: @unchecked Sendable {
    struct Outcome { var status: Int32; var stdout: String; var stderr: String; var timedOut: Bool }

    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let script: String
    // Guarded by `lock`:
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var timedOut = false

    init(script: String, arguments: [String]) {
        self.script = script
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"] + arguments   // "-" reads the program from stdin
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func run(timeout: TimeInterval) async throws -> Outcome {
        try Task.checkCancellation()
        stdout.fileHandleForReading.readabilityHandler = { [self] handle in append(handle.availableData, toError: false) }
        stderr.fileHandleForReading.readabilityHandler = { [self] handle in append(handle.availableData, toError: true) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, Error>) in
            process.terminationHandler = { [self] process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                out.append(stdout.fileHandleForReading.readDataToEndOfFile())
                err.append(stderr.fileHandleForReading.readDataToEndOfFile())
                let outcome = Outcome(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self), timedOut: timedOut)
                lock.unlock()
                if process.terminationReason == .uncaughtSignal && !outcome.timedOut {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(returning: outcome)
                }
            }
            do {
                try process.run()
                try stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try stdin.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: ImportError.conversionFailed(app: "osascript", message: error.localizedDescription))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                lock.lock()
                let running = process.isRunning
                if running { timedOut = true }
                lock.unlock()
                if running { process.terminate() }
            }
        }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func append(_ data: Data, toError: Bool) {
        lock.lock()
        if toError { err.append(data) } else { out.append(data) }
        lock.unlock()
    }
}
