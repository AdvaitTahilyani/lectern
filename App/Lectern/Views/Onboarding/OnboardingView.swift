import SwiftUI
import LecternCore

/// First-launch onboarding, 4 steps (DESIGN.md §4.11).
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var hero
    @State private var step = 0
    @State private var permission: MicrophonePermission = .notDetermined
    @State private var level: Float = 0
    @State private var levelMonitor: (any AudioLevelMonitoring)?
    @State private var levelTask: Task<Void, Never>?
    @State private var keys: [ProviderKind: String] = [:]
    @State private var tests: [ProviderKind: SettingsModel.TestState] = [:]
    @State private var downloadsStarted = false

    private let speechID = TranscriptionEngineID.parakeet.rawValue
    private let llmID = AppSettings.defaultOnDeviceModel

    var body: some View {
        VStack(spacing: 0) {
            heroArea
            content
                .frame(maxWidth: 400)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, DS.Space.huge)
            footer
        }
        .frame(width: DS.Layout.onboarding.width, height: DS.Layout.onboarding.height)
        .background(DS.Colors.canvas)
        .onAppear { permission = app.services.microphonePermission() }
        .onChange(of: step) { _, s in
            if s == 1 { startMeter() } else { stopMeter() }
            if s == 2, !downloadsStarted { startDownloads() }
        }
    }

    private var heroArea: some View {
        ZStack {
            Group {
                switch step {
                case 0: LecternGlyphView(size: 96).foregroundStyle(DS.Colors.accent)
                case 1: Image(systemName: "mic.fill").font(.system(size: 72)).foregroundStyle(DS.Colors.accent)
                case 2: Image(systemName: "arrow.down.circle.dotted").font(.system(size: 72)).foregroundStyle(DS.Colors.accent)
                default: Image(systemName: "cloud.fill").font(.system(size: 72)).foregroundStyle(DS.Colors.accent)
                }
            }
            .matchedGeometryEffect(id: "hero", in: hero)
            .transition(.opacity)
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .animation(DS.Motion.settle, value: step)
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            switch step {
            case 0:
                Text("Lectern listens so you can look up.").font(DS.Typo.title)
                Text("Live takeaways from every lecture, on your Mac.").font(DS.Typo.body).foregroundStyle(.secondary)
            case 1:
                Text("Lectern needs your microphone.").font(DS.Typo.title)
                Text("Audio is processed on this Mac and is not stored unless you choose to.").font(DS.Typo.body).foregroundStyle(.secondary)
                if permission == .granted {
                    LevelMeter(level: level, peak: level, width: 200)
                } else {
                    Button("Allow Microphone") {
                        Task { permission = await app.services.requestMicrophoneAccess() ? .granted : .denied; if permission == .granted { startMeter() } }
                    }
                    .buttonStyle(.bordered)
                    if permission == .denied { Text("You can grant access later in System Settings.").font(DS.Typo.footnote).foregroundStyle(.secondary) }
                }
            case 2:
                Text("Download the on-device models").font(DS.Typo.title)
                downloadRow(id: speechID, name: "Parakeet (speech)")
                downloadRow(id: llmID, name: "\(app.shortModelName(llmID)) (summaries, quizzes, Ask)")
                Text(downloadEstimate).font(DS.Typo.footnote).foregroundStyle(.secondary)
            default:
                Text("Optional: cloud models for Ask").font(DS.Typo.title)
                keyRow(.anthropic)
                keyRow(.openAI)
                Text("You can add these later in Settings.").font(DS.Typo.footnote).foregroundStyle(.secondary)
            }
        }
        .id(step)
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
        .animation(DS.Motion.settle, value: step)
    }

    private var footer: some View {
        HStack {
            if step == 3 { Button("Skip") { finish() }.buttonStyle(.link).font(DS.Typo.footnote) }
            Spacer()
            HStack(spacing: DS.Space.s) {
                ForEach(0..<4, id: \.self) { i in Circle().fill(i == step ? AnyShapeStyle(DS.Colors.accent) : AnyShapeStyle(.quaternary)).frame(width: 6, height: 6) }
            }
            Spacer()
            Button(step == 3 ? "Done" : (step == 2 && !allInstalled ? "Continue while downloading" : "Continue")) {
                if step == 3 { finish() } else { withAnimation(DS.Motion.settle) { step += 1 } }
            }
            .lecternProminent()
            .keyboardShortcut(.defaultAction)
        }
        .padding(DS.Space.xxl)
    }

    // MARK: Helpers

    private var allInstalled: Bool { app.modelState(speechID).isInstalled && app.modelState(llmID).isInstalled }

    private var downloadEstimate: String {
        let total = app.services.onDeviceModels.catalog.filter { [speechID, llmID].contains($0.id) }.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let remaining = app.services.onDeviceModels.catalog.filter { [speechID, llmID].contains($0.id) }.reduce(0.0) { $0 + Double($1.sizeBytes) * (1 - (app.modelState($1.id).progress ?? 0)) }
        let rate = 45_000_000.0
        let minutes = max(1, Int((remaining / rate / 60).rounded()))
        return "\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · ~\(minutes) min on campus Wi-Fi"
    }

    private func downloadRow(id: String, name: String) -> some View {
        let state = app.modelState(id)
        return HStack(spacing: DS.Space.m) {
            Circle().fill(state.isInstalled ? DS.Colors.correct : DS.Colors.accent).frame(width: 8, height: 8)
            Text(name).lineLimit(1)
            Spacer()
            switch state {
            case .installed: Label("done", systemImage: "checkmark").font(DS.Typo.footnote).foregroundStyle(.secondary)
            case .downloading(let p, _), .paused(let p):
                ProgressView(value: p).frame(width: 80)
                Text("\(Int(p * 100))%").font(DS.Typo.mono).contentTransition(.numericText())
            case .failed: Button("Retry") { app.services.onDeviceModels.download(id: id) }.controlSize(.small)
            case .notInstalled: ProgressView().controlSize(.small)
            }
        }
        .font(DS.Typo.body)
    }

    private func keyRow(_ kind: ProviderKind) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(kind.displayName).frame(width: 80, alignment: .leading)
            SecureField("API key", text: Binding(get: { keys[kind] ?? "" }, set: { keys[kind] = $0 })).textFieldStyle(.roundedBorder)
            Button("Test") { test(kind) }.controlSize(.small)
            switch tests[kind] ?? .idle {
            case .testing: ProgressView().controlSize(.small)
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Colors.correct)
            case .failed(let m): Image(systemName: "xmark.circle.fill").foregroundStyle(DS.Colors.review).help(m)
            case .idle: EmptyView()
            }
        }
    }

    private func test(_ kind: ProviderKind) {
        let key = keys[kind] ?? ""
        tests[kind] = .testing
        Task {
            do {
                let h = try await app.services.providerHealthCheck(ProviderConfig(kind: kind, model: SettingsModel.cloudModels[kind]?.first ?? ""), key)
                try? app.services.keychain.setAPIKey(key, for: kind)
                tests[kind] = .ok(latencyMs: h.latencyMilliseconds, detail: h.detail)
            } catch {
                tests[kind] = .failed(error.localizedDescription)
            }
        }
    }

    private func startDownloads() {
        downloadsStarted = true
        for id in [speechID, llmID] where !app.modelState(id).isInstalled {
            if case .paused = app.modelState(id) { app.services.onDeviceModels.resume(id: id) } else if case .downloading = app.modelState(id) {} else { app.services.onDeviceModels.download(id: id) }
        }
    }

    private func startMeter() {
        guard permission == .granted, levelTask == nil else { return }
        let m = app.services.makeLevelMonitor()
        levelMonitor = m
        let stream = m.start(deviceID: nil)
        levelTask = Task { for await v in stream { level = v } }
    }

    private func stopMeter() {
        levelTask?.cancel(); levelTask = nil
        levelMonitor?.stop(); levelMonitor = nil
    }

    private func finish() {
        stopMeter()
        app.completeOnboarding()
        openWindow(id: "main")
        dismissWindow(id: "onboarding")
    }
}
