import Foundation
import Testing
@testable import LecternImport

/// Audit B42: process and pipe handling of the osascript runner, exercised with ordinary
/// programs in place of osascript.
@Suite struct OsaScriptRunnerTests {
    private func runner(_ program: String) -> OsaScriptRunner { OsaScriptRunner(executable: URL(fileURLWithPath: program)) }

    @Test func passesTheScriptThroughStandardInput() async throws {
        let output = try await runner("/bin/cat").run("hello from stdin", arguments: [], application: "Test", timeout: 10)
        #expect(output == "hello from stdin")
    }

    @Test func aStdinWriteThatFailsAfterLaunchCompletesTheCallExactlyOnce() async {
        // `true` exits at once without reading; a script far larger than the pipe buffer then
        // cannot be written. The failed write and the process's termination both used to resume
        // the same continuation.
        let script = String(repeating: "x", count: 4_000_000)
        for _ in 0..<5 {
            do {
                _ = try await runner("/usr/bin/true").run(script, arguments: [], application: "Test", timeout: 10)
            } catch {
                // Either outcome is fine; what matters is that the call returned once.
            }
        }
    }

    @Test func aCancellationBeforeLaunchIsNotMissed() async {
        let job = OsaScriptJob(executable: URL(fileURLWithPath: "/bin/cat"), script: "never", arguments: [])
        job.terminate()   // arrives before the process exists
        await #expect(throws: CancellationError.self) { try await job.run(timeout: 10) }
        #expect(!job.didLaunch)
    }

    @Test func aMissingProgramFailsCleanly() async {
        await #expect(throws: ImportError.self) {
            try await runner("/nonexistent/osascript").run("x", arguments: [], application: "Test", timeout: 10)
        }
    }
}
