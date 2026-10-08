import SwiftUI
import LecternCore
import LecternLLM

/// Settings window (DESIGN.md §4.10): General · Transcription · Models · Quizzes · Focus.
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        let model = app.settingsModel
        TabView(selection: $app.settingsTab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings(model: model) }
            Tab("Transcription", systemImage: "waveform", value: "transcription") { TranscriptionSettings(model: model) }
            Tab("Models", systemImage: "cpu", value: "models") { ModelsSettings(model: model) }
            Tab("Quizzes", systemImage: "questionmark.circle", value: "quizzes") { QuizSettingsView(model: model) }
            Tab("Focus", systemImage: "rectangle.inset.topright.filled", value: "focus") { FocusSettings(model: model) }
        }
        .frame(width: DS.Layout.settingsWidth)
    }
}

// MARK: - General

struct GeneralSettings: View {
    var model: SettingsModel
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: Binding(get: { model.preferences.appearance }, set: { v in model.updatePreferences { $0.appearance = v } })) {
                    Text("System").tag(UIPreferences.Appearance.system)
                    Text("Light").tag(UIPreferences.Appearance.light)
                    Text("Dark").tag(UIPreferences.Appearance.dark)
                }
                .pickerStyle(.segmented)
                Toggle("Show menu bar status while recording", isOn: Binding(get: { model.preferences.showMenuBarWhileRecording }, set: { v in model.updatePreferences { $0.showMenuBarWhileRecording = v } }))
            }
            Section("Storage") {
                LabeledContent("Location") {
                    HStack {
                        Text(model.storageLocation.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(DS.Typo.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([model.storageLocation]) }.controlSize(.small)
                    }
                }
                LabeledContent("Used", value: model.storageSummary)
            }
            Section("While you were away") {
                Toggle("Catch me up when I come back", isOn: Binding(get: { model.preferences.showRecapWhenBack }, set: { v in model.updatePreferences { $0.showRecapWhenBack = v } }))
                Picker("After being away for", selection: Binding(get: { model.preferences.awayThresholdSeconds }, set: { v in model.updatePreferences { $0.awayThresholdSeconds = v } })) {
                    Text("30 seconds").tag(30.0)
                    Text("1½ minutes").tag(90.0)
                    Text("3 minutes").tag(180.0)
                    Text("5 minutes").tag(300.0)
                }
                .disabled(!model.preferences.showRecapWhenBack)
            }
            Section("Privacy") {
                Label {
                    Text("With on-device models selected, audio, slides and transcripts never leave this Mac. Cloud providers receive transcript excerpts and slide text for the roles you assign them.")
                        .font(DS.Typo.footnote).foregroundStyle(.secondary)
                } icon: { Image(systemName: "lock.fill") }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshStorage() }
    }
}

// MARK: - Transcription

struct TranscriptionSettings: View {
    @Bindable var model: SettingsModel
    @Environment(AppModel.self) private var app

    /// The speech model's size from the one catalog Models also shows (QA Q3-6).
    private var speechModelSize: String {
        let bytes = model.catalog.first { $0.id == TranscriptionEngineID.parakeet.rawValue }?.sizeBytes ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Engine", selection: Binding(get: { model.settings.transcriptionEngine }, set: { model.setEngine($0) })) {
                    VStack(alignment: .leading) {
                        Text("Parakeet — on-device, Neural Engine")
                        Text("Best accuracy and custom vocabulary. \(speechModelSize) download.").font(DS.Typo.footnote).foregroundStyle(.secondary)
                    }.tag(TranscriptionEngineID.parakeet)
                    VStack(alignment: .leading) {
                        Text("Apple Speech — on-device fallback")
                        Text("No download; tuned for lectures and meetings. No custom vocabulary.").font(DS.Typo.footnote).foregroundStyle(.secondary)
                    }.tag(TranscriptionEngineID.apple)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                LabeledContent("Status") {
                    HStack(spacing: DS.Space.s) {
                        let state = model.modelState(TranscriptionEngineID.parakeet.rawValue)
                        if model.settings.transcriptionEngine == .apple || state.isInstalled {
                            Circle().fill(DS.Colors.correct).frame(width: 8, height: 8)
                            Text(model.settings.transcriptionEngine == .apple ? "Ready · system model" : "Ready · \(speechModelSize)")
                        } else if let p = state.progress {
                            ProgressView(value: p).frame(width: 80)
                            Text("Downloading \(Int(p * 100))%").contentTransition(.numericText())
                        } else {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning)
                            Text("Not downloaded")
                            Button("Download") { model.download(TranscriptionEngineID.parakeet.rawValue) }.controlSize(.small)
                        }
                    }
                }
            }
            Section("Microphone") {
                LabeledContent("Input") {
                    HStack(spacing: DS.Space.m) {
                        Picker("Input", selection: Binding(get: { model.selectedInputDeviceID }, set: { model.setInputDevice($0) })) {
                            ForEach(model.inputDevices) { d in Text(d.name).tag(d.id) }
                        }
                        .labelsHidden()
                        if model.isMicrophoneInUse {
                            LevelMeter(level: model.recordingLevel, peak: model.recordingLevel, width: 120)
                                .help("In use by the current lecture")
                        } else {
                            LevelMeter(level: model.level, peak: model.peak, width: 120)
                        }
                    }
                }
            }
            Section {
                Toggle("Fix course jargon from slides", isOn: Binding(get: { model.settings.fixesJargonFromSlides }, set: { model.setFixesJargon($0) }))
                Text("When the lecture's deck uses a term, misheard versions of it are corrected, like “gen expression” → genExpr or “L are” → LR. Corrected words are underlined with dots in the transcript; hover to see what was heard.")
                    .font(DS.Typo.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Slides")
            }
            Section {
                List(selection: $model.selectedVocabulary) {
                    ForEach(model.settings.vocabulary, id: \.self) { term in Text(term).tag(term) }
                        .onDelete { model.removeVocabulary(at: $0) }
                }
                .frame(minHeight: 120)
                .onDeleteCommand { model.removeSelectedVocabulary() }
                HStack(spacing: DS.Space.s) {
                    TextField("Add a term", text: $model.newVocabularyTerm).textFieldStyle(.roundedBorder).onSubmit { model.addVocabulary() }
                    Button { model.addVocabulary() } label: { Image(systemName: "plus") }.disabled(model.newVocabularyTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button { model.removeSelectedVocabulary() } label: { Image(systemName: "minus") }.disabled(model.selectedVocabulary == nil)
                    Spacer()
                    Button("Import from slide decks…") { model.importVocabularyFromDecks() }
                }
                Text("Words and names the transcriber should recognize.").font(DS.Typo.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Custom vocabulary")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.startLevel() }
        .onDisappear { model.stopLevel() }
        .onChange(of: model.isMicrophoneInUse) { _, inUse in if inUse { model.stopLevel() } else { model.startLevel() } }
    }
}

// MARK: - Models

struct ModelsSettings: View {
    @Bindable var model: SettingsModel
    @State private var openGroups: Set<ProviderKind> = []

    var body: some View {
        Form {
            Section {
                ForEach(LLMRole.allCases) { role in roleRow(role) }
                Text("Each role can use a different provider. On-device keeps everything private.").font(DS.Typo.footnote).foregroundStyle(.secondary)
            } header: { Text("Roles") }
            if model.isMeteringUsage { spendingSection }
            Section("Providers") {
                DisclosureGroup(isExpanded: binding(.onDevice)) { onDeviceGroup } label: { Text("On-device (MLX)") }
                DisclosureGroup(isExpanded: binding(.localServer)) { localServerGroup } label: { Text("Local server (Ollama / LM Studio)") }
                DisclosureGroup(isExpanded: binding(.openAI)) { cloudGroup(.openAI) } label: { Text("OpenAI") }
                DisclosureGroup(isExpanded: binding(.anthropic)) { cloudGroup(.anthropic) } label: { Text("Anthropic") }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            openGroups = Set(model.settings.providers.values.map(\.kind))
            model.startUsageUpdates()
        }
        .onDisappear { model.stopUsageUpdates() }
    }

    // MARK: Cloud spending

    private var spendingSection: some View {
        Section {
            LabeledContent(model.usage.monthName.isEmpty ? "This month" : model.usage.monthName) {
                Text(model.usage.totalUSD, format: .currency(code: "USD"))
                    .font(DS.Typo.mono)
                    .contentTransition(.numericText())
            }
            ForEach(model.usage.lines) { line in
                LabeledContent {
                    Text(line.costUSD, format: .currency(code: "USD")).font(DS.Typo.mono).foregroundStyle(.secondary)
                } label: {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("\(line.provider.displayName) · \(line.model)")
                        Text(usageDetail(line)).font(DS.Typo.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Monthly cap") {
                HStack(spacing: DS.Space.s) {
                    if model.monthlyCap != nil {
                        TextField("Cap", value: Binding(get: { model.monthlyCap ?? 10 }, set: { model.setMonthlyCap($0) }), format: .currency(code: "USD"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .accessibilityLabel("Monthly cap in dollars")
                    }
                    Toggle("Monthly cap", isOn: Binding(get: { model.monthlyCap != nil }, set: { model.setCapEnabled($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
            if let problem = model.usage.storageProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Typo.footnote)
                    .foregroundStyle(DS.Colors.warning)
            }
            if model.isCapReached {
                Label(
                    model.hasOnDeviceFallback ? "Cap reached. Cloud roles use the on-device model until next month." : "Cap reached. Cloud roles are paused until next month or a higher cap.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(DS.Typo.footnote)
                .foregroundStyle(DS.Colors.warning)
            }
            Text("From each provider's list prices per 1M tokens; prompt-cache reads cost a tenth of fresh input (Anthropic cache writes 1.25×). Calls that were cancelled or reported no usage are estimated. On-device and local-server models are free. A cloud call that could take spending past the cap is held back, and cloud roles switch to the on-device model if it's downloaded.")
                .font(DS.Typo.footnote).foregroundStyle(.secondary)
        } header: {
            Text("Cloud spending")
        }
    }

    private func usageDetail(_ line: UsageMonthSummary.Line) -> String {
        let tokens = (line.inputTokens + line.outputTokens).formatted(.number.notation(.compactName))
        var parts = ["\(line.calls) call\(line.calls == 1 ? "" : "s")", "\(tokens) tokens"]
        if line.inputTokens > 0, line.cachedInputTokens > 0 {
            parts.append("\(Int((Double(line.cachedInputTokens) / Double(line.inputTokens) * 100).rounded()))% cached")
        }
        if line.isEstimate { parts.append("includes estimates") }
        return parts.joined(separator: " · ")
    }

    private func binding(_ kind: ProviderKind) -> Binding<Bool> {
        Binding(get: { openGroups.contains(kind) }, set: { if $0 { openGroups.insert(kind) } else { openGroups.remove(kind) } })
    }

    private func roleRow(_ role: LLMRole) -> some View {
        let config = model.settings.provider(for: role)
        // A plain row (not LabeledContent, which combines its children into one text node for
        // accessibility): each popup stays an individual labeled control with its value (QA AX).
        // The pickers' titles are their accessibility labels; an extra `.accessibilityLabel`
        // read the name twice (QA Q3-6).
        return HStack(spacing: DS.Space.s) {
            Text(role.displayName).frame(width: 84, alignment: .leading)
            Picker("\(role.displayName) provider", selection: Binding(get: { config.kind }, set: { model.setProvider($0, for: role) })) {
                ForEach(ProviderKind.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().frame(width: 150)
            Picker("\(role.displayName) model", selection: Binding(get: { config.model }, set: { model.setModel($0, for: role) })) {
                ForEach(model.models(for: config.kind), id: \.self) { id in Text(displayName(id, kind: config.kind)).tag(id) }
                if !model.models(for: config.kind).contains(config.model) { Text(displayName(config.model, kind: config.kind)).tag(config.model) }
            }
            .labelsHidden().frame(minWidth: 140, maxWidth: 240)
            .help(displayName(config.model, kind: config.kind))
            .accessibilityValue(displayName(config.model, kind: config.kind))
            // The model popup gives way, so the status ("Not downloaded  Download") is never cut off.
            roleStatus(role, config: config).fixedSize()
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func roleStatus(_ role: LLMRole, config: ProviderConfig) -> some View {
        if model.roleNeedsDownload(role) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Colors.warning)
                Text("Not downloaded").font(DS.Typo.footnote)
                Button("Download") { model.download(config.model); openGroups.insert(.onDevice) }.buttonStyle(.link).font(DS.Typo.footnote)
            }
        } else if config.kind.isCloud {
            HStack(spacing: DS.Space.xs) {
                Circle().fill(model.isKeyStored(config.kind) ? DS.Colors.correct : DS.Colors.warning).frame(width: 8, height: 8)
                Text(model.isKeyStored(config.kind) ? "Key OK" : "No key").font(DS.Typo.footnote)
            }
        } else {
            HStack(spacing: DS.Space.xs) {
                Circle().fill(DS.Colors.correct).frame(width: 8, height: 8)
                Text("Ready").font(DS.Typo.footnote)
            }
        }
    }

    private func displayName(_ id: String, kind: ProviderKind) -> String {
        switch kind {
        case .onDevice: return model.catalog.first { $0.id == id }?.displayName ?? id
        case .openAI, .anthropic: return ProviderCatalog.suggestedModels(for: kind).first { $0.id == id }?.displayName ?? id
        case .localServer: return id
        }
    }

    private var onDeviceGroup: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(model.catalog) { info in downloadRow(info) }
            Text("Models live in Storage › Location. \(ByteCountFormatter.string(fromByteCount: model.freeSpace, countStyle: .file)) free.").font(DS.Typo.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, DS.Space.xs)
    }

    private func downloadRow(_ info: OnDeviceModelInfo) -> some View {
        let state = model.modelState(info.id)
        return HStack(spacing: DS.Space.m) {
            Text(info.displayName).frame(width: 200, alignment: .leading).lineLimit(1)
            Text(ByteCountFormatter.string(fromByteCount: info.sizeBytes, countStyle: .file)).font(DS.Typo.mono).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
            switch state {
            case .installed:
                Circle().fill(DS.Colors.correct).frame(width: 8, height: 8)
                Text("Installed").font(DS.Typo.footnote)
                Spacer()
                Button("Remove") { model.remove(info.id) }.controlSize(.small)
            case .downloading(let p, let rate):
                Image(systemName: "arrow.down.circle").foregroundStyle(DS.Colors.accent)
                Text("\(Int(p * 100))%").font(DS.Typo.mono).contentTransition(.numericText()).frame(width: 36)
                ProgressView(value: p).frame(maxWidth: 120)
                if let rate { Text("\(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file))/s").font(DS.Typo.footnote).foregroundStyle(.secondary) }
                Spacer()
                Button("Pause") { model.pause(info.id) }.controlSize(.small)
            case .paused(let p):
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                Text("\(Int(p * 100))%").font(DS.Typo.mono).frame(width: 36)
                ProgressView(value: p).frame(maxWidth: 120)
                Spacer()
                Button("Resume") { model.resume(info.id) }.controlSize(.small)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(DS.Colors.warning)
                Text(reason).font(DS.Typo.footnote).lineLimit(1)
                Spacer()
                Button("Retry") { model.download(info.id) }.controlSize(.small)
            case .notInstalled:
                Spacer()
                Button("Download") { model.download(info.id) }.controlSize(.small)
            }
        }
        .frame(minHeight: 24)
    }

    private var localServerGroup: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            LabeledContent("URL") {
                HStack {
                    TextField("URL", text: $model.localServerURL, prompt: Text("http://localhost:11434/v1")).labelsHidden().textFieldStyle(.roundedBorder).onSubmit { model.commitLocalServer() }
                    testButton(.localServer)
                    testStatus(.localServer)
                }
            }
            LabeledContent("Model") {
                TextField("Model", text: $model.localServerModel, prompt: Text("qwen3:8b")).labelsHidden().textFieldStyle(.roundedBorder).onSubmit { model.commitLocalServer() }
            }
        }
        .padding(.vertical, DS.Space.xs)
    }

    private func cloudGroup(_ kind: ProviderKind) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            LabeledContent("API key") {
                HStack {
                    SecureField("API key", text: Binding(get: { model.keyDraft(kind) }, set: { model.setKeyDraft($0, for: kind) }), prompt: Text(model.isKeyStored(kind) ? "••••••••••••••••••••" : "Paste your key"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.commitKey(kind) }
                    if model.hasKeyDraft(kind) {
                        Button("Save") { model.commitKey(kind) }.controlSize(.small)
                    }
                    testButton(kind)
                    testStatus(kind)
                }
            }
            if model.isKeyStored(kind) {
                HStack(spacing: DS.Space.s) {
                    Label("Stored in Keychain", systemImage: "key.fill").font(DS.Typo.footnote).foregroundStyle(.secondary)
                    Button("Remove key") { model.removeKey(kind) }.buttonStyle(.link).font(DS.Typo.footnote)
                }
            }
            LabeledContent("Model") {
                Picker("Model", selection: Binding(get: { selectedModel(kind) }, set: { m in
                    for role in LLMRole.allCases where model.settings.provider(for: role).kind == kind { model.setModel(m, for: role) }
                })) {
                    ForEach(ProviderCatalog.suggestedModels(for: kind)) { m in Text([m.displayName, m.priceDescription].compactMap { $0 }.joined(separator: " · ")).tag(m.id) }
                    if !model.models(for: kind).contains(selectedModel(kind)) { Text(selectedModel(kind)).tag(selectedModel(kind)) }
                }
                .labelsHidden().frame(width: 380)
                .accessibilityLabel("\(kind.displayName) model")
            }
        }
        .padding(.vertical, DS.Space.xs)
    }

    /// The model the roles using `kind` have selected (the first role's), else the default.
    private func selectedModel(_ kind: ProviderKind) -> String {
        LLMRole.allCases.first { model.settings.provider(for: $0).kind == kind }.map { model.settings.provider(for: $0).model } ?? model.defaultModel(for: kind)
    }

    private func testButton(_ kind: ProviderKind) -> some View {
        Button("Test") { model.test(kind) }.controlSize(.small).disabled(model.testState(kind) == .testing)
    }

    @ViewBuilder private func testStatus(_ kind: ProviderKind) -> some View {
        switch model.testState(kind) {
        case .idle: EmptyView()
        case .testing: ProgressView().controlSize(.small)
        case .ok(let ms, let detail):
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Colors.correct)
                Text("OK · \(ms) ms\(detail.map { " · \($0)" } ?? "")").font(DS.Typo.footnote).lineLimit(1)
            }
        case .failed(let message):
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(DS.Colors.review)
                Text(message).font(DS.Typo.footnote).lineLimit(1)
            }
        }
    }
}

// MARK: - Quizzes

struct QuizSettingsView: View {
    var model: SettingsModel
    var body: some View {
        Form {
            Section("Timing") {
                let current = model.settings.quiz.enabled ? model.settings.quiz.intervalMinutes : 0
                let intervals = ([5.0, 10, 15, 20] + (current > 0 && ![5.0, 10, 15, 20].contains(current) ? [current] : [])).sorted()
                Picker("Ask me a question every", selection: Binding(get: { current }, set: { v in model.updateQuiz { $0.enabled = v > 0; if v > 0 { $0.intervalMinutes = v } } })) {
                    ForEach(intervals, id: \.self) { m in Text(m == m.rounded() ? "\(Int(m)) min" : String(format: "%.1f min", m)).tag(m) }
                    Text("Off").tag(0.0)
                }
                Picker("Style", selection: Binding(get: { model.preferences.quizStyle }, set: { v in model.updatePreferences { $0.quizStyle = v } })) {
                    Text("Card").tag(UIPreferences.QuizStyle.card)
                    Text("Toolbar badge only").tag(UIPreferences.QuizStyle.badge)
                }
                .pickerStyle(.radioGroup)
            }
            Section("Questions") {
                Toggle("Multiple choice", isOn: Binding(get: { model.settings.quiz.allowMultipleChoice }, set: { v in model.updateQuiz { $0.allowMultipleChoice = v } }))
                Toggle("Short answer", isOn: Binding(get: { model.settings.quiz.allowShortAnswer }, set: { v in model.updateQuiz { $0.allowShortAnswer = v } }))
                Picker("Difficulty", selection: Binding(get: { model.settings.quiz.difficulty }, set: { v in model.updateQuiz { $0.difficulty = v } })) {
                    Text("Easier").tag(QuizSettings.Difficulty.gentle)
                    Text("Balanced").tag(QuizSettings.Difficulty.standard)
                    Text("Harder").tag(QuizSettings.Difficulty.challenging)
                }
                .pickerStyle(.segmented)
                Toggle("Follow up when I get one wrong", isOn: Binding(get: { model.preferences.followUpWhenWrong }, set: { v in model.updatePreferences { $0.followUpWhenWrong = v } }))
                Toggle("Show streaks", isOn: Binding(get: { model.preferences.showStreaks }, set: { v in model.updatePreferences { $0.showStreaks = v } }))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Focus

struct FocusSettings: View {
    var model: SettingsModel
    var body: some View {
        Form {
            Section("Focus panel") {
                Toggle("Show on every screen (all Spaces)", isOn: Binding(get: { model.preferences.focusPanelAllSpaces }, set: { v in model.updatePreferences { $0.focusPanelAllSpaces = v } }))
                Toggle("Dim when idle", isOn: Binding(get: { model.preferences.focusPanelDimWhenIdle }, set: { v in model.updatePreferences { $0.focusPanelDimWhenIdle = v } }))
                LabeledContent("Shortcut") {
                    HStack(spacing: DS.Space.s) {
                        Text("⌘⇧F").font(DS.Typo.mono).padding(.horizontal, DS.Space.s).padding(.vertical, DS.Space.xxs).background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                        Text("Works while Lectern is frontmost; a global hotkey arrives in a later version.").font(DS.Typo.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Accessibility") {
                Toggle("Announce new takeaways with VoiceOver", isOn: Binding(get: { model.preferences.announceNewTakeaways }, set: { v in model.updatePreferences { $0.announceNewTakeaways = v } }))
            }
        }
        .formStyle(.grouped)
    }
}
