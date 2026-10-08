import SwiftUI
import LecternCore

// MARK: - LiveDot

struct LiveDot: View {
    enum State { case recording, paused, idle }
    var state: State
    var size: CGFloat = DS.Size.liveDot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.State private var pulsing = false

    var body: some View {
        ZStack {
            if state == .recording, !reduceMotion {
                Circle()
                    .fill(DS.Colors.recording)
                    .scaleEffect(pulsing ? 1.6 : 1)
                    .opacity(pulsing ? 0 : 0.35)
                    .animation(.easeOut(duration: DS.Motion.livePulsePeriod).repeatForever(autoreverses: false), value: pulsing)
                    .onAppear { pulsing = true }
                    .onDisappear { pulsing = false }
            }
            Circle().fill(fill)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(label)
    }

    private var fill: AnyShapeStyle {
        switch state {
        case .recording: AnyShapeStyle(DS.Colors.recording)
        case .paused: AnyShapeStyle(.secondary)
        case .idle: AnyShapeStyle(.quaternary)
        }
    }

    private var label: String {
        switch state {
        case .recording: "Recording"
        case .paused: "Paused"
        case .idle: "Not recording"
        }
    }
}

// MARK: - SessionClock

/// Glass capsule with the live dot and elapsed time. Clicking toggles pause.
struct SessionClock: View {
    var elapsed: TimeInterval
    var state: LiveSessionModel.RecordingState
    var onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: DS.Space.s) {
                if state == .paused {
                    Image(systemName: "pause.fill").font(.caption2).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                } else {
                    LiveDot(state: state == .recording ? .recording : .idle).accessibilityHidden(true)
                }
                Text(state == .paused ? "Paused · \(TimeFormat.clock(elapsed))" : TimeFormat.clock(elapsed))
                    .font(DS.Typo.monoBody)
                    .contentTransition(.numericText(countsDown: false))
            }
            .padding(.horizontal, DS.Space.m)
            .frame(height: 24)
        }
        .buttonStyle(.plain)
        .lecternGlass(.regular.interactive(), in: .capsule)
        .help(state == .paused ? "Resume recording" : "Pause recording")
        .accessibilityLabel(state == .paused ? "Paused" : "Recording")
        .accessibilityValue(accessibilityTime)
        .accessibilityHint(state == .paused ? "Double-tap to resume" : "Double-tap to pause")
    }

    /// Updated per minute, not per second, to avoid VoiceOver chatter.
    private var accessibilityTime: String {
        let m = TimeFormat.wholeSeconds(elapsed) / 60
        return "\(m) minute\(m == 1 ? "" : "s")"
    }
}

/// Review-mode stats capsule. With a `sessionID`, the lecture's cloud API cost is appended when
/// it isn't zero.
struct StatsCapsule: View {
    var duration: TimeInterval
    var takeaways: Int
    var score: (correct: Int, total: Int)
    var sessionID: UUID? = nil
    @Environment(AppModel.self) private var app
    @State private var apiCost: Double = 0

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(TimeFormat.clock(duration))
            Text("·").foregroundStyle(.tertiary)
            Text("\(takeaways) takeaway\(takeaways == 1 ? "" : "s")")
            if score.total > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(score.correct)/\(score.total) ✓")
            }
            if apiCost > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text(apiCost, format: .currency(code: "USD").precision(.fractionLength(apiCost < 0.1 ? 3 : 2)))
                    .help("Cloud API cost of this lecture")
                    .accessibilityLabel("API cost \(apiCost.formatted(.currency(code: "USD")))")
            }
        }
        .task(id: sessionID) {
            guard let sessionID, let usage = app.services.usage else { return }
            for await _ in await usage.changes() {
                let cost = await usage.cost(forSession: sessionID)
                if cost != apiCost { apiCost = cost }
            }
        }
        .font(DS.Typo.mono)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.m)
        .frame(height: 24)
        .lecternGlass(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - LevelMeter

struct LevelMeter: View {
    var level: Float
    var peak: Float
    var width: CGFloat = 160
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let segments = 20
    private let gap: CGFloat = 2

    var body: some View {
        let segWidth = (width - gap * CGFloat(segments - 1)) / CGFloat(segments)
        HStack(spacing: gap) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: DS.Radius.chip / 3, style: .continuous)
                    .fill(fill(for: i))
                    .frame(width: segWidth, height: DS.Size.levelMeterHeight)
            }
        }
        .frame(width: width, height: DS.Size.levelMeterHeight)
        .animation(reduceMotion ? nil : .linear(duration: 0.05), value: level)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func fill(for index: Int) -> AnyShapeStyle {
        let threshold = Float(index + 1) / Float(segments)
        if level >= 0.95, index == segments - 1 { return AnyShapeStyle(DS.Colors.warning) }
        if level >= threshold { return AnyShapeStyle(DS.Colors.accent) }
        if !reduceMotion, peak >= threshold, peak < threshold + 1 / Float(segments) { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.quaternary)
    }
}

// MARK: - ModelStatusBadge

struct ModelStatusBadge: View {
    enum Style { case compact, expanded }
    var status: ModelStatus
    var style: Style
    var detail: String? = nil
    var onDetails: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: DS.Space.s) {
            indicator
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryText)
                    .font(style == .compact ? DS.Typo.footnote : DS.Typo.subheadline)
                    .foregroundStyle(style == .compact ? .secondary : .primary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                if style == .expanded, let detail {
                    Text(detail).font(DS.Typo.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if style == .expanded, let onDetails {
                Spacer(minLength: DS.Space.s)
                Button("Details", action: onDetails).buttonStyle(.link).font(DS.Typo.footnote)
            }
        }
        .frame(minHeight: style == .compact ? 28 : 36)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var indicator: some View {
        switch status {
        case .ready:
            Circle().fill(DS.Colors.correct).frame(width: 8, height: 8)
        case .downloading(let p):
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 2)
                Circle().trim(from: 0, to: p).stroke(DS.Colors.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
        case .cloud:
            Image(systemName: "cloud.fill").font(.caption).foregroundStyle(.secondary)
        case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(DS.Colors.warning)
        case .checking:
            ProgressView().controlSize(.mini)
        }
    }

    private var primaryText: String {
        switch status {
        case .ready(let engine): style == .compact ? "On-device · Ready" : "On-device · \(engine) ready"
        case .downloading(let p): "Downloading \(Int(p * 100))%"
        case .cloud(let provider): style == .compact ? "\(provider) · Cloud" : "Cloud · \(provider)"
        case .unavailable(let reason): style == .compact ? "Unavailable" : reason
        case .checking: "Checking models…"
        }
    }
}

// MARK: - Chips

struct SlideChip: View {
    enum Style { case inline, thumb }
    var page: Int
    var endPage: Int? = nil
    var thumbnail: NSImage? = nil
    var style: Style = .inline
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                if style == .thumb {
                    SlideImage(image: thumbnail, page: page)
                        .frame(width: 32, height: 18)
                }
                Text(label)
                    .font(style == .thumb ? DS.Typo.footnote : DS.Typo.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, style == .thumb ? DS.Space.xs : DS.Space.s)
            .padding(.vertical, style == .thumb ? 3 : 0)
            .frame(minHeight: style == .thumb ? 24 : 20)
            .foregroundStyle(DS.Colors.accent)
            .background(DS.Colors.accent.opacity(hovered ? 0.2 : 0.12), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.hover, value: hovered)
        .help("Show slide \(page)")
        .accessibilityLabel(label)
    }

    private var label: String {
        if let endPage, endPage != page { return "Slides \(page)–\(endPage)" }
        return "Slide \(page)"
    }
}

struct TimestampChip: View {
    enum Style { case gutter, inline, range(TimeInterval) }
    var time: TimeInterval
    var style: Style = .inline
    var tooltip: String? = nil
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(DS.Typo.mono)
                .foregroundStyle(foreground)
                .underline(isGutter && hovered)
                .padding(.horizontal, isGutter ? 0 : DS.Space.s)
                .frame(width: isGutter ? 48 : nil, height: isGutter ? nil : 20, alignment: .trailing)
                .background(isGutter ? AnyShapeStyle(.clear) : AnyShapeStyle(.secondary.opacity(hovered ? 0.2 : 0.12)), in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DS.Motion.hover, value: hovered)
        .help(tooltip ?? "Show related slide")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isGutter ? "Shows the slide and topic at this time" : tooltip ?? "Shows related slide")
    }

    private var isGutter: Bool { if case .gutter = style { true } else { false } }

    private var foreground: AnyShapeStyle {
        if isGutter { return hovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary) }
        return AnyShapeStyle(.secondary)
    }

    private var label: String {
        if case .range(let end) = style { return "\(TimeFormat.clock(time))–\(TimeFormat.clock(end))" }
        return TimeFormat.clock(time)
    }

    private var accessibilityLabel: String {
        let whole = TimeFormat.wholeSeconds(time), m = whole / 60, s = whole % 60
        return "\(m) minute\(m == 1 ? "" : "s") \(s) second\(s == 1 ? "" : "s")"
    }
}

struct TermChip: View {
    var term: KeyTerm
    var onFindInTranscript: (() -> Void)? = nil
    @State private var showPopover = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        Button { showPopover.toggle() } label: {
            Text(term.term)
                .font(DS.Typo.callout)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xxs)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    if !Task.isCancelled { showPopover = true }
                }
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(term.term).font(DS.Typo.headline)
                Text(term.definition).font(DS.Typo.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let onFindInTranscript {
                    Button("Find in transcript") { showPopover = false; onFindInTranscript() }.buttonStyle(.link).font(DS.Typo.footnote)
                }
            }
            .padding(DS.Space.l)
            .frame(maxWidth: 280, alignment: .leading)
        }
        .accessibilityLabel("\(term.term). \(term.definition)")
    }
}

/// Key-cap glyph for quiz options and shortcut hints.
struct KeyCap: View {
    var text: String
    var body: some View {
        Text(text)
            .font(DS.Typo.mono)
            .frame(width: 18, height: 18)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(DS.Colors.hairline))
            .accessibilityHidden(true)
    }
}

// MARK: - Slide image

/// A slide thumbnail with hairline stroke and the dark-mode dim (DESIGN.md §10).
struct SlideImage: View {
    var image: NSImage?
    var page: Int
    var isCurrent: Bool = false
    var radius: CGFloat = DS.Radius.control
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .brightness(colorScheme == .dark && !isCurrent && contrast != .increased ? -0.08 : 0)
            } else {
                Rectangle().fill(.quaternary)
                Image(systemName: "doc.text").foregroundStyle(.secondary).font(.caption)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(DS.Colors.hairline, lineWidth: 1))
        .accessibilityLabel("Slide \(page)")
    }
}

// MARK: - Score ring

struct ScoreRing: View {
    var correct: Int
    var total: Int
    var size: CGFloat = 64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 6)
            Circle().trim(from: 0, to: progress)
                .stroke(DS.Colors.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(correct)/\(total)")
                .font(DS.Typo.title2.monospacedDigit())
                .fontWeight(.semibold)
        }
        .frame(width: size, height: size)
        .onAppear(perform: showScore)
        .onChange(of: correct) { showScore() }
        .onChange(of: total) { showScore() }
        .accessibilityLabel("\(correct) of \(total) correct")
    }

    private func showScore() {
        let target = total > 0 ? Double(correct) / Double(total) : 0
        if reduceMotion { progress = target } else { withAnimation(DS.Motion.settle) { progress = target } }
    }
}

// MARK: - Lectern glyph (custom symbol stand-in)

/// The lectern glyph from the app icon, drawn as a shape so it works at any size and in
/// hierarchical/monochrome contexts. Used for the empty state, onboarding hero and menu bar.
struct LecternGlyph: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        path.move(to: p(0.13, 0.42)); path.addLine(to: p(0.57, 0.27)); path.addLine(to: p(0.57, 0.36)); path.addLine(to: p(0.13, 0.51)); path.closeSubpath()
        path.move(to: p(0.31, 0.50)); path.addLine(to: p(0.39, 0.475)); path.addLine(to: p(0.39, 0.78)); path.addLine(to: p(0.31, 0.78)); path.closeSubpath()
        path.move(to: p(0.19, 0.86)); path.addLine(to: p(0.51, 0.86)); path.addLine(to: p(0.44, 0.78)); path.addLine(to: p(0.26, 0.78)); path.closeSubpath()
        for (i, len) in [0.24, 0.18, 0.12].enumerated() {
            let y = 0.33 + CGFloat(i) * 0.12
            path.move(to: p(0.66, y)); path.addLine(to: p(0.66 + len, y))
        }
        return path
    }
}

struct LecternGlyphView: View {
    var size: CGFloat
    var body: some View {
        LecternGlyph()
            .stroke(style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round, lineJoin: .round))
            .fill(.clear)
            .background(LecternGlyph().fill(.primary))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension LecternGlyph {
    /// Template image for the menu bar (rendered at 2×).
    @MainActor static func templateImage(size: CGFloat = 18, recordingDot: NSColor? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let path = LecternGlyph().path(in: rect.insetBy(dx: 1, dy: 1)).cgPath
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(path)
            ctx.setStrokeColor(.black); ctx.setFillColor(.black)
            ctx.setLineWidth(size * 0.07); ctx.setLineJoin(.round); ctx.setLineCap(.round)
            ctx.drawPath(using: .fillStroke)
            if let recordingDot {
                ctx.setFillColor(recordingDot.cgColor)
                ctx.fillEllipse(in: CGRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 5, height: 5))
            }
            return true
        }
        image.isTemplate = recordingDot == nil
        return image
    }
}
