import SwiftUI
import LecternCore

/// Quiz ping card (DESIGN.md §4.6). Rendered inside the same `GlassEffectContainer` as the Now
/// card; keyboard 1–4 / ↩ / S / Esc are handled by the owner when no text field has focus.
struct QuizCard: View {
    var quiz: LiveSessionModel.ActiveQuiz
    var streak: Int
    var showStreak: Bool
    var sessionID: UUID
    var thumbnail: (Int) -> NSImage? = { _ in nil }
    var onSelect: (Int) -> Void
    var onShortAnswerChange: (String) -> Void
    var onSubmitShort: () -> Void
    var onSnooze: () -> Void
    var onSkip: () -> Void
    var onDismiss: () -> Void
    var onHover: (Bool) -> Void
    var onOpenURL: (URL) -> Void
    var compactWidth: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dsAnimation) private var motion
    @FocusState private var shortAnswerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            switch quiz.phase {
            case .asking, .grading:
                header
                question(quiz.question, disabled: quiz.phase == .grading)
            case .correct(let grade):
                resultHeader(correct: true)
                chosen(for: quiz.question)
                feedback(grade)
            case .wrong(let grade, let followUp, let pending):
                resultHeader(correct: false)
                feedback(grade)
                if let followUp {
                    Divider()
                    Text("Try this one:").font(DS.Typo.subheadline).foregroundStyle(.secondary)
                    question(followUp, disabled: false)
                } else if pending {
                    Text("Another question is on the way…").font(DS.Typo.footnote).foregroundStyle(.secondary)
                }
            case .gradingFollowUp(let grade, let followUp):
                resultHeader(correct: false)
                feedback(grade)
                Divider()
                question(followUp, disabled: true)
            case .followUpResult(_, let followUp, let result):
                resultHeader(correct: result.isCorrect)
                chosen(for: followUp)
                feedback(result)
            }
            if showStreak, streak >= 2, !quiz.isResult {
                HStack {
                    Spacer()
                    Text("🔥 \(streak) in a row").font(DS.Typo.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lecternGlass(.regular, in: .rect(cornerRadius: DS.Radius.float))
        .onHover(perform: onHover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quiz")
        .onAppear { if case .shortAnswer = quiz.question.kind { shortAnswerFocused = true } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            DeadlineRing(deadline: quiz.deadline, paused: quiz.phase == .grading)
            Text("Quick check · \(quiz.question.concept)")
                .font(DS.Typo.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                .lineLimit(1)
            if quiz.phase == .grading { ProgressView().controlSize(.mini) }
            Spacer()
            Button("Snooze", action: onSnooze).keyboardShortcut("s", modifiers: []).help("Ask again in 5 minutes (S)")
            Button("Skip", action: onSkip).help("Skip this question (Esc)")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.mini)
    }

    private func resultHeader(correct: Bool) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: correct ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill")
                .foregroundStyle(correct ? DS.Colors.correct : DS.Colors.review)
                .symbolEffect(.bounce, options: .nonRepeating, isActive: correct && !reduceMotion)
            Text(correct ? "Correct" : "Not quite").font(DS.Typo.headline)
            Spacer()
            if showStreak, correct, streak >= 2 { Text("🔥 \(streak) in a row").font(DS.Typo.footnote).foregroundStyle(.secondary) }
            Button(action: onDismiss) { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss")
        }
    }

    // MARK: Question

    @ViewBuilder private func question(_ q: QuizQuestion, disabled: Bool) -> some View {
        Text(q.prompt).font(DS.Typo.title3).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        switch q.kind {
        case .multipleChoice(let options, _):
            let compact = compactWidth == false && options.allSatisfy { $0.count < 18 } && q.followUpOf != nil
            if compact {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: DS.Space.s) {
                    optionRows(options, disabled: disabled)
                }
            } else {
                VStack(spacing: DS.Space.xs + 2) { optionRows(options, disabled: disabled) }
            }
        case .shortAnswer:
            HStack(spacing: DS.Space.s) {
                TextField("Type a short answer…", text: Binding(get: { quiz.shortAnswer }, set: onShortAnswerChange))
                    .textFieldStyle(.plain)
                    .font(DS.Typo.body)
                    .frame(height: 20)
                    .focused($shortAnswerFocused)
                    .onSubmit(onSubmitShort)
                    .disabled(disabled)
                Button(action: onSubmitShort) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .buttonStyle(.plain)
                    .foregroundStyle(quiz.shortAnswer.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(DS.Colors.accent))
                    .disabled(quiz.shortAnswer.trimmingCharacters(in: .whitespaces).isEmpty || disabled)
                    .accessibilityLabel("Submit answer")
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: 36)
            .lecternGlass(.regular.interactive(), in: .capsule)
        }
    }

    private func optionRows(_ options: [String], disabled: Bool) -> some View {
        ForEach(Array(options.enumerated()), id: \.offset) { i, option in
            OptionRow(index: i, text: option, selected: quiz.selectedOption == i, disabled: disabled) { onSelect(i) }
        }
    }

    private func chosen(for q: QuizQuestion) -> some View {
        Group {
            if case .multipleChoice(let options, _) = q.kind, let i = quiz.selectedOption, options.indices.contains(i) {
                Text(options[i]).font(DS.Typo.body)
            } else if case .shortAnswer = q.kind {
                EmptyView()
            }
        }
    }

    private func feedback(_ grade: QuizGrade) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(grade.feedback)
                .font(DS.Typo.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if !grade.citations.isEmpty {
                CitationRow(citations: grade.citations, sessionID: sessionID, thumbnail: thumbnail, onOpen: onOpenURL)
            }
        }
    }
}

/// One MCQ option: 36 pt, key-cap glyph, accent on selection for 150 ms before submit.
struct OptionRow: View {
    var index: Int
    var text: String
    var selected: Bool
    var disabled: Bool
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                KeyCap(text: "\(index + 1)")
                    .foregroundStyle(selected ? .white : .primary)
                Text(text).font(DS.Typo.body).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs)
            .frame(minHeight: 30)
            .foregroundStyle(selected ? .white : .primary)
            .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
        .animation(DS.Motion.hover, value: hovered)
        .accessibilityLabel("Option \(index + 1): \(text)")
    }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(DS.Colors.accent) }
        if hovered, !disabled { return AnyShapeStyle(DS.Colors.accent.opacity(0.12)) }
        return AnyShapeStyle(.quaternary)
    }
}

/// 16 pt ring draining to the deadline; a `mono` countdown under Reduce Motion.
struct DeadlineRing: View {
    var deadline: Date
    var paused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 0.25)) { timeline in
            let remaining = max(0, deadline.timeIntervalSince(timeline.date))
            let total = max(1, deadline.timeIntervalSince(Date.now) + (Date.now.timeIntervalSince(timeline.date)))
            if reduceMotion {
                Text(TimeFormat.clock(remaining)).font(DS.Typo.mono).foregroundStyle(.secondary)
            } else {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2)
                    Circle().trim(from: 0, to: min(1, remaining / max(total, 90)))
                        .stroke(paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(DS.Colors.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Row of citation chips (slides as thumbs, timestamps inline), wrapping when needed.
struct CitationRow: View {
    var citations: [Citation]
    var sessionID: UUID
    var thumbnail: (Int) -> NSImage? = { _ in nil }
    var onOpen: (URL) -> Void

    var body: some View {
        FlowLayout(spacing: DS.Space.s) {
            ForEach(Array(citations.enumerated()), id: \.offset) { _, c in
                switch c {
                case .slide(let n):
                    SlideChip(page: n, thumbnail: thumbnail(n), style: .thumb) { onOpen(LecternURL.slide(session: sessionID, page: n)) }
                case .time(let t):
                    TimestampChip(time: t, style: .inline, tooltip: "Show in transcript") { onOpen(LecternURL.time(session: sessionID, seconds: t)) }
                }
            }
        }
    }
}
