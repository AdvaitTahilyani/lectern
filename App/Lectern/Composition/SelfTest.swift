import Foundation
import LecternCore
import LecternMLX

/// Headless checks of the real stack from inside the app bundle, where resource lookup (MLX's
/// metallib, CoreML model caches) differs from `swift test`. Launch the app binary with
/// `-selftest mlx`, `-selftest pipeline …` (see PipelineSelfTest) or `-selftest ask …` (see AskSelfTest); it prints results to stdout and exits with status 0 on success.
nonisolated enum SelfTest {
    static var requested: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-selftest"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func runIfRequested() {
        guard let name = requested else { return }
        Task.detached {
            let ok: Bool
            switch name {
            case "mlx": ok = await mlx()
            case "pipeline": ok = await PipelineSelfTest.run(arguments: CommandLine.arguments)
            case "ask": ok = await AskSelfTest.run(arguments: CommandLine.arguments)
            default:
                print("[selftest] unknown test \(name)")
                ok = false
            }
            exit(ok ? 0 : 1)
        }
    }

    private static func mlx() async -> Bool {
        let model = AppSettings.defaultOnDeviceModel
        let provider = MLXProvider(model: model, role: .summaries)
        do {
            let start = ContinuousClock.now
            try await provider.warmUp()
            print("[selftest] mlx warm-up \(start.duration(to: .now))")
            let request = LLMRequest(
                messages: [.system("You are a concise teaching assistant."), .user("In one sentence: what is an LL(1) parser?")],
                maxTokens: 60, temperature: 0.2
            )
            let result = try await provider.completeWithMetrics(request)
            let m = result.metrics
            print("[selftest] mlx reply: \(result.response.text)")
            print("[selftest] mlx ttft \(String(format: "%.2f", m.timeToFirstToken)) s, decode \(String(format: "%.1f", m.decodeTokensPerSecond)) tok/s, peak \(m.peakMemoryBytes / 1_000_000) MB")
            return !result.response.text.isEmpty
        } catch {
            print("[selftest] mlx FAILED: \(error)")
            return false
        }
    }
}
