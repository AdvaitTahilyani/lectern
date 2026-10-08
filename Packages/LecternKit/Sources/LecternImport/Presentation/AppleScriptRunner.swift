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
    /// The program that reads the script from standard input; replaceable so tests can run other
    /// programs through the same process handling.
    var executable = URL(fileURLWithPath: "/usr/bin/osascript")

    func run(_ script: String, arguments: [String], application: String, timeout: TimeInterval) async throws -> String {
        let job = OsaScriptJob(executable: executable, script: script, arguments: arguments)
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

/// One run of the scripting program. The result is delivered through a `OneShot`, so the process's
/// termination, a failed stdin write and a failed launch can race freely: whichever comes first
/// completes the call and the rest are ignored.
final class OsaScriptJob: @unchecked Sendable {
    struct Outcome: Sendable { var status: Int32; var stdout: String; var stderr: String; var timedOut: Bool }

    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let script: String
    private let completion = OneShot<Outcome>()
    // Guarded by `lock`:
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var timedOut = false
    private var cancelled = false
    private var launched = false
    private var inputFailure: String?

    init(executable: URL, script: String, arguments: [String]) {
        self.script = script
        process.executableURL = executable
        process.arguments = ["-"] + arguments   // "-" reads the program from stdin
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
    }

    /// True once the process has been started (for tests).
    var didLaunch: Bool { lock.lock(); defer { lock.unlock() }; return launched }

    func run(timeout: TimeInterval) async throws -> Outcome {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Outcome, Error>) in
            completion.install(continuation)
            launch(timeout: timeout)
        }
    }

    private func launch(timeout: TimeInterval) {
        // A cancellation that arrived before the process existed must not be lost: `terminate()`
        // could not stop anything then, so the flag is checked under the same lock that records
        // the launch, and again after it.
        lock.lock()
        if cancelled {
            lock.unlock()
            closePipes()
            completion.finish(.failure(CancellationError()))
            return
        }
        stdout.fileHandleForReading.readabilityHandler = { [self] handle in append(handle.availableData, toError: false) }
        stderr.fileHandleForReading.readabilityHandler = { [self] handle in append(handle.availableData, toError: true) }
        process.terminationHandler = { [self] process in processDidTerminate(process) }
        do {
            try process.run()
        } catch {
            lock.unlock()
            closePipes()
            completion.finish(.failure(ImportError.conversionFailed(app: "osascript", message: error.localizedDescription)))
            return
        }
        launched = true
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { process.terminate() }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            lock.lock()
            let running = process.isRunning
            if running { timedOut = true }
            lock.unlock()
            if running { process.terminate() }
        }

        // Writing to a process that has already exited must fail with an error, not kill us.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try stdin.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        } catch {
            // The process will not get its script. Stop it; if it has already exited, its own
            // outcome stands. Either way termination (not this failure) completes the call.
            lock.lock(); inputFailure = error.localizedDescription; lock.unlock()
            if process.isRunning { process.terminate() }
        }
        try? stdin.fileHandleForWriting.close()
    }

    private func processDidTerminate(_ process: Process) {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        let tailOut = stdout.fileHandleForReading.readDataToEndOfFile()
        let tailErr = stderr.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        out.append(tailOut)
        err.append(tailErr)
        let outcome = Outcome(status: process.terminationStatus, stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self), timedOut: timedOut)
        let inputFailure = inputFailure
        lock.unlock()
        closePipes()
        if process.terminationReason == .uncaughtSignal && !outcome.timedOut {
            completion.finish(.failure(inputFailure.map { ImportError.conversionFailed(app: "osascript", message: "couldn't send the script (\($0))") } ?? CancellationError()))
        } else {
            completion.finish(.success(outcome))
        }
    }

    /// Stops the process, or, when it has not started yet, makes the start a cancellation.
    func terminate() {
        lock.lock()
        cancelled = true
        let running = launched
        lock.unlock()
        if running, process.isRunning { process.terminate() }
    }

    private func closePipes() {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
    }

    private func append(_ data: Data, toError: Bool) {
        lock.lock()
        if toError { err.append(data) } else { out.append(data) }
        lock.unlock()
    }
}
