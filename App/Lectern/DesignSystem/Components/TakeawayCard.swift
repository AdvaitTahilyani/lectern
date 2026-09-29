import SwiftUI
import LecternCore

enum TakeawayCardState: Hashable {
    case live(elapsed: TimeInterval)
    case settled
    case placeholder
}

/// The app's signature object (DESIGN.md §5). `.live` lives in the glass dock, `.settled` in the
/// opaque list; the same `matchedGeometryEffect` id carries it between the two.
struct TakeawayCard: View {
    var takeaway: Takeaway?
    var state: TakeawayCardState
    var isExpanded: Bool = false
    var isFocused: Bool = false
    var quizMarker: QuizOutcome?? = nil
    var compact: Bool = false
    var thumbnail: (Int) -> NSImage? = { _ in nil }
    var onToggleExpand: () -> Void = {}
    var onShowSlide: (Int) -> Void = { _ in }
    var onSeek: (TimeInterval) -> Void = { _ in }
    var onAsk: () -> Void = {}
    var onCopy: () -> Void = {}
    var onFindTerm: (String) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dsAnimation) private var motion
    @State private var hovered = false

    var body: some View {
        switch state {
        case .placeholder: placeholder
        case .live(let elapsed): live(elapsed: elapsed)
        case .settled: settled
        }
    }

    // MARK: Placeholder

    private var placeholder: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "ellipsis")
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                .foregroundStyle(.secondary)
            Text("Listening for the next topic…")
                .font(DS.Typo.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    // MARK: Live

    private func live(elapsed: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: compact ? 0 : DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                LiveDot(state: .recording, size: DS.Size.liveDotSmall).accessibilityHidden(true)
                Text("NOW").font(DS.Typo.caption).fontWeight(.semibold).tracking(0.5).foregroundStyle(.secondary)
                Text("· \(Int(elapsed / 60)) min").font(DS.Typo.mono).foregroundStyle(.secondary).contentTransition(.numericText())
                if compact, let takeaway {
                    Text(takeaway.title).font(DS.Typo.headline).lineLimit(1).contentTransition(.opacity)
                }
            }
            if !compact, let takeaway {
                Text(takeaway.title)
                    .font(DS.Typo.headline)
                    .contentTransition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Space.xxs)
                Text(takeaway.summary)
                    .font(DS.Typo.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .lineSpacing(DS.Typo.summaryLineSpacing)
                    .contentTransition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(motion.morph, value: takeaway?.title)
        .animation(motion.morph, value: takeaway?.summary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, compact ? DS.Space.s : DS.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current topic: \(takeaway?.title ?? ""). \(takeaway?.summary ?? "")")
    }

    // MARK: Settled

    private var settled: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(takeaway?.title ?? "")
                    .font(DS.Typo.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.s)
                if let t = takeaway {
                    TimestampChip(time: t.start, style: .range(t.end)) { onSeek(t.start) }
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            Text(takeaway?.summary ?? "")
                .font(DS.Typo.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 2)
                .lineSpacing(DS.Typo.summaryLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
            if isExpanded, let t = takeaway { expandedDetails(t) }
            footer
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .surfaceCard(radius: DS.Radius.card, raised: hovered || isExpanded, strokeColor: hovered ? Color(nsColor: .separatorColor) : nil)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card + 3, style: .continuous)
                .strokeBorder(DS.Colors.accent, lineWidth: 2)
                .padding(-3)
                .opacity(isFocused ? 1 : 0)
        )
        .onHover { hovered = $0 }
        .animation(motion.hover, value: hovered)
        .onTapGesture { onToggleExpand() }
        .accessibilityElement(children: isExpanded ? .contain : .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isExpanded ? "Double-tap to collapse" : "Double-tap to expand")
        .accessibilityAction(named: "Ask about this", onAsk)
        .accessibilityAction(named: "Copy", onCopy)
    }

    @ViewBuilder private var footer: some View {
        if let t = takeaway, !t.slidePages.isEmpty || quizMarker != nil {
            HStack(spacing: DS.Space.s) {
                if let first = t.slidePages.first {
                    SlideChip(page: first, endPage: t.slidePages.last, style: .inline) { onShowSlide(first) }
                }
                if let quizMarker {
                    switch quizMarker {
                    case .some(.correct):
                        Label("Quizzed", systemImage: "checkmark.seal").labelStyle(.iconOnly).foregroundStyle(DS.Colors.correct).help("Quiz answered correctly")
                    case .some(.incorrect):
                        Label("To review", systemImage: "arrow.uturn.backward.circle").labelStyle(.iconOnly).foregroundStyle(DS.Colors.review).help("Missed on the quiz")
                    case .some(.skipped):
                        Label("Skipped", systemImage: "minus.circle").labelStyle(.iconOnly).foregroundStyle(.secondary).help("Quiz skipped")
                    case .none:
                        Label("Quiz", systemImage: "questionmark.circle").labelStyle(.iconOnly).foregroundStyle(.secondary).help("Quiz pending")
                    }
                }
                Spacer()
            }
            .font(DS.Typo.caption)
            .frame(height: 20)
        }
    }

    @ViewBuilder private func expandedDetails(_ t: Takeaway) -> some View {
        if let d = t.detail {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(Array(d.bullets.enumerated()), id: \.offset) { _, b in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                        Text("•").frame(width: 12, alignment: .leading)
                        Text(b).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(DS.Typo.body)
                }
                if let e = d.example {
                    Text(e).font(DS.Typo.body).italic().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, DS.Space.xxs)
                }
            }
            .padding(.top, DS.Space.xxs)
            if !d.keyTerms.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Key terms").font(DS.Typo.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: DS.Space.xs) {
                        ForEach(d.keyTerms) { k in TermChip(term: k) { onFindTerm(k.term) } }
                    }
                }
            }
        } else {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "waveform").symbolEffect(.variableColor.iterative.reversing, isActive: !reduceMotion).foregroundStyle(.secondary)
                Text("Expanding…").font(DS.Typo.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, DS.Space.xs)
        }
        if !t.slidePages.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Slides").font(DS.Typo.caption).foregroundStyle(.secondary)
                HStack(spacing: DS.Space.s) {
                    ForEach(t.slidePages.prefix(6), id: \.self) { p in
                        Button { onShowSlide(p) } label: {
                            SlideImage(image: thumbnail(p), page: p, radius: DS.Radius.chip)
                                .frame(width: DS.Size.cardThumb.width, height: DS.Size.cardThumb.height)
                        }
                        .buttonStyle(.plain)
                        .help("Show slide \(p)")
                    }
                }
            }
        }
        HStack(spacing: DS.Space.m) {
            TimestampChip(time: t.start, style: .range(t.end), tooltip: "Show in transcript") { onSeek(t.start) }
            Spacer()
            Button { onAsk() } label: { Label("Ask about this", systemImage: "sparkle.magnifyingglass") }
                .buttonStyle(.borderless).controlSize(.small)
            Button { onCopy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .buttonStyle(.borderless).controlSize(.small)
                .keyboardShortcut("c", modifiers: .command)
        }
        .font(DS.Typo.caption)
        .padding(.top, DS.Space.xxs)
    }

    private var accessibilityLabel: String {
        guard let t = takeaway else { return "" }
        var parts = [t.title, "\(TimeFormat.clock(t.start)) to \(TimeFormat.clock(t.end))"]
        if let f = t.slidePages.first, let l = t.slidePages.last { parts.append(f == l ? "slide \(f)" : "slides \(f) to \(l)") }
        switch quizMarker {
        case .some(.correct): parts.append("quizzed correctly")
        case .some(.incorrect): parts.append("missed on the quiz")
        default: break
        }
        parts.append("Summary: \(t.summary)")
        return parts.joined(separator: ", ")
    }
}
