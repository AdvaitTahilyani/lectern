import SwiftUI
import LecternCore

/// Review › Quiz tab: score ring, missed concepts, and every question (DESIGN.md §4.9).
struct QuizTabView: View {
    var session: LiveSessionModel
    @State private var expanded: UUID?

    var body: some View {
        let score = session.quizScore
        let missed = session.missedConcepts.count
        let records = session.quizRecords.filter { $0.outcome != nil && $0.question.followUpOf == nil }
        ScrollView {
            VStack(spacing: DS.Space.l) {
                if records.isEmpty {
                    EmptyStateView(symbol: "questionmark.circle", title: "No quiz yet", message: "Quick checks appear every few minutes during a lecture.", style: .compact)
                } else {
                    VStack(spacing: DS.Space.s) {
                        ScoreRing(correct: score.correct, total: score.total)
                        Text(missed == 0 ? "All concepts on track" : "\(missed) concept\(missed == 1 ? "" : "s") to review").font(DS.Typo.subheadline).foregroundStyle(.secondary)
                        if missed > 0 {
                            Button("Review missed concepts") { session.startReviewMissed() }.lecternProminent()
                        }
                    }
                    .padding(.top, DS.Space.m)
                    Divider()
                    VStack(spacing: DS.Space.xs) {
                        ForEach(records) { r in row(r) }
                    }
                }
            }
            .padding(DS.Space.l)
        }
    }

    private func row(_ r: QuizRecord) -> some View {
        let isOpen = expanded == r.id
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            Button { withAnimation(DS.Motion.settle) { expanded = isOpen ? nil : r.id } } label: {
                HStack(spacing: DS.Space.s) {
                    outcomeIcon(r.outcome)
                    Text(TimeFormat.clock(r.askedAt)).font(DS.Typo.mono).foregroundStyle(.secondary)
                    Text(r.question.concept).font(DS.Typo.body).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary).rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(r.question.prompt).font(DS.Typo.headline).fixedSize(horizontal: false, vertical: true)
                    if let answer = answerText(r) {
                        Text("Your answer: \(answer)").font(DS.Typo.subheadline)
                    } else {
                        Text("Skipped").font(DS.Typo.subheadline).foregroundStyle(.secondary)
                    }
                    if let g = r.grade {
                        Text(g.feedback).font(DS.Typo.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !g.citations.isEmpty {
                            CitationRow(citations: g.citations, sessionID: session.id, thumbnail: { session.slideImages?.image(page: $0, width: 32) }, onOpen: { _ = session.open($0) })
                        }
                    }
                }
                .padding(.leading, DS.Space.xxl)
                .transition(.opacity)
            }
        }
        .padding(.vertical, DS.Space.xs)
        .accessibilityElement(children: .combine)
    }

    private func answerText(_ r: QuizRecord) -> String? {
        guard let a = r.answer else { return nil }
        if case .multipleChoice(let options, _) = r.question.kind, let i = Int(a), options.indices.contains(i) { return options[i] }
        return a
    }

    @ViewBuilder func outcomeIcon(_ o: QuizOutcome?) -> some View {
        switch o {
        case .correct: Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Colors.correct)
        case .incorrect: Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(DS.Colors.review)
        case .skipped, nil: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }
}

/// "Review missed concepts": one concept at a time in place of the takeaway list.
struct ReviewMissedView: View {
    @Bindable var session: LiveSessionModel
    var flow: LiveSessionModel.ReviewFlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shortAnswer = ""

    var body: some View {
        VStack(spacing: DS.Space.l) {
            HStack(spacing: DS.Space.xs) {
                ForEach(0..<max(1, flow.concepts.count), id: \.self) { i in
                    Circle().fill(i == flow.index ? AnyShapeStyle(DS.Colors.accent) : AnyShapeStyle(.quaternary)).frame(width: 6, height: 6)
                }
            }
            .padding(.top, DS.Space.l)
            if flow.isFinished {
                VStack(spacing: DS.Space.m) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 48)).foregroundStyle(DS.Colors.correct)
                        .symbolEffect(.bounce, options: .nonRepeating, isActive: !reduceMotion)
                    Text("All caught up").font(DS.Typo.title2)
                    Button("Back to lecture") { session.exitReview() }.lecternProminent().keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let c = flow.current {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        Text("\(flow.index + 1) of \(flow.concepts.count) · \(c.record.question.concept)").font(DS.Typo.caption).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.5)
                        if let t = c.takeaway {
                            Text(t.title).font(DS.Typo.title3)
                            Text(t.summary).font(DS.Typo.body).lineSpacing(DS.Typo.summaryLineSpacing).fixedSize(horizontal: false, vertical: true)
                            ForEach(Array((t.detail?.bullets ?? []).enumerated()), id: \.offset) { _, b in
                                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) { Text("•"); Text(b) }.font(DS.Typo.body)
                            }
                        }
                        if let g = c.record.grade {
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                Text("From the lecture").font(DS.Typo.caption).foregroundStyle(.secondary)
                                Text(g.feedback).font(DS.Typo.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        let slides = c.record.question.sourceSlides + (c.takeaway?.slidePages ?? [])
                        if !slides.isEmpty {
                            HStack(spacing: DS.Space.s) {
                                ForEach(Array(Set(slides)).sorted().prefix(4), id: \.self) { p in
                                    Button { session.showSlide(p) } label: {
                                        SlideImage(image: session.slideImages?.image(page: p, width: DS.Size.slideThumb.width), page: p)
                                            .frame(width: DS.Size.slideThumb.width, height: DS.Size.slideThumb.height)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Divider()
                        freshQuestion
                    }
                    .padding(DS.Space.xl)
                    .frame(maxWidth: 560, alignment: .leading)
                    .surfaceCard()
                    .padding(.horizontal, DS.Space.l)
                    .frame(maxWidth: .infinity)
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
                .id(c.id)
                HStack {
                    Button("Exit") { session.exitReview() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Skip") { session.reviewNext() }
                    Button("Next") { session.reviewNext() }.lecternProminent().keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, DS.Space.xl).padding(.bottom, DS.Space.l)
                .frame(maxWidth: 560 + 2 * DS.Space.l)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(DS.Motion.settle, value: flow.index)
        .onChange(of: flow.index) { _, _ in shortAnswer = "" }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), (1...4).contains(n), flow.freshGrade == nil, flow.freshQuestion != nil else { return .ignored }
            session.reviewSelect(n - 1)
            return .handled
        }
    }

    @ViewBuilder private var freshQuestion: some View {
        if let q = flow.freshQuestion {
            Text("Try again").font(DS.Typo.caption).foregroundStyle(.secondary)
            Text(q.prompt).font(DS.Typo.headline).fixedSize(horizontal: false, vertical: true)
            switch q.kind {
            case .multipleChoice(let options, _):
                VStack(spacing: DS.Space.s) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                        OptionRow(index: i, text: o, selected: flow.freshSelected == i, disabled: flow.freshGrade != nil || flow.isGrading) { session.reviewSelect(i) }
                    }
                }
            case .shortAnswer:
                HStack {
                    TextField("Type a short answer…", text: $shortAnswer).textFieldStyle(.roundedBorder).onSubmit { session.reviewSubmit(answer: shortAnswer) }
                    Button("Check") { session.reviewSubmit(answer: shortAnswer) }.disabled(shortAnswer.isEmpty || flow.freshGrade != nil)
                }
            }
            if let g = flow.freshGrade {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Image(systemName: g.isCorrect ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill").foregroundStyle(g.isCorrect ? DS.Colors.correct : DS.Colors.review)
                    Text(g.feedback).font(DS.Typo.subheadline).fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            } else if flow.isGrading {
                HStack(spacing: DS.Space.s) { ProgressView().controlSize(.small); Text("Checking…").font(DS.Typo.footnote).foregroundStyle(.secondary) }
            }
        } else {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "waveform").symbolEffect(.variableColor.iterative.reversing, isActive: !reduceMotion).foregroundStyle(.secondary)
                Text("Writing a fresh question…").font(DS.Typo.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
