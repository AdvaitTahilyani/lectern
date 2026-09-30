import SwiftUI

/// Design tokens from `docs/DESIGN.md` §3. Only these values appear in layout code.
nonisolated enum DS {

    // MARK: Spacing (4-pt base scale).
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
        static let huge: CGFloat = 40
        /// Inset of floating glass objects from the edge of their container.
        static let floatInset: CGFloat = 12
    }

    // MARK: Corner radii. Nested radii follow (outer − padding).
    enum Radius {
        static let chip: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let float: CGFloat = 16
        static let panel: CGFloat = 20
    }

    // MARK: Layout widths (points)
    enum Layout {
        static let windowMin = CGSize(width: 720, height: 520)
        static let windowDefault = CGSize(width: 1280, height: 800)
        static let sidebar = (min: 200.0, ideal: 240.0, max: 320.0)
        static let slidesColumn = (min: 200.0, ideal: 240.0, max: 320.0)
        static let takeawaysMin: CGFloat = 420
        static let inspector = (min: 300.0, ideal: 340.0, max: 480.0)
        static let readingMaxWidth: CGFloat = 640
        /// Live layout breakpoints, measured on the detail column's width.
        static let threeColumnMin: CGFloat = 1180
        static let twoColumnMin: CGFloat = 860
        static let focusPanel = CGSize(width: 340, height: 160)
        static let focusPanelWithQuiz = CGSize(width: 340, height: 248)
        static let settingsWidth: CGFloat = 620
        static let onboarding = CGSize(width: 560, height: 640)
    }

    // MARK: Motion.
    enum Motion {
        /// Cards settling, columns resizing, expand/collapse.
        static let settle = Animation.spring(duration: 0.45, bounce: 0.15)
        /// Small UI: pills appearing, chips, hover states.
        static let quick = Animation.spring(duration: 0.28, bounce: 0.20)
        /// Floating objects entering (quiz card, banners).
        static let float = Animation.spring(duration: 0.40, bounce: 0.25)
        /// Text refinement crossfade (Now card title/summary morph).
        static let morph = Animation.smooth(duration: 0.35)
        /// Numeric counters (elapsed time, counts).
        static let numeric = Animation.snappy(duration: 0.25)
        /// Fallback when Reduce Motion is on: a plain fade.
        static let reduced = Animation.easeInOut(duration: 0.18)
        /// Hover lifts.
        static let hover = Animation.easeOut(duration: 0.15)

        static func resolve(_ a: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? reduced : a
        }
        /// Live dot pulse period; disabled under Reduce Motion.
        static let livePulsePeriod: Double = 1.2
    }

    // MARK: Colors. Semantic first; named assets only where the system has no equivalent.
    enum Colors {
        static let accent = Color.accentColor
        static let recording = Color.red
        static let correct = Color.green
        static let review = Color.orange
        static let warning = Color.yellow

        /// Canvas behind content in the detail column. An opaque asset (not `windowBackgroundColor`,
        /// which is translucent on macOS 26 and let the Library show through under a session).
        static let canvas = Color("Canvas")
        /// Opaque card surface.
        static let surface = Color("Surface")
        /// Slightly raised surface (expanded card, hovered row).
        static let surfaceRaised = Color("SurfaceRaised")
        /// 1-pt hairline around cards.
        static let hairline = Color("Hairline")
        /// Volatile (in-progress) transcript text.
        static let volatileText = Color.secondary
        /// Search-hit highlight.
        static let searchHit = Color("SearchHit")

        /// Course colors: index = courseColorIndex % 8.
        static let course: [Color] = [.indigo, .teal, .orange, .pink, .green, .purple, .brown, .cyan]

        /// Resolves a course's stored `colorHex` (or a stable palette entry when absent).
        static func course(_ hex: String?, fallbackIndex: Int) -> Color {
            if let hex, let c = Color(hex: hex) { return c }
            return course[abs(fallbackIndex) % course.count]
        }
    }

    // MARK: Typography.
    enum Typo {
        static let title = Font.title
        static let title2 = Font.title2
        static let title3 = Font.title3
        static let headline = Font.headline
        static let body = Font.body
        static let callout = Font.callout
        static let subheadline = Font.subheadline
        static let footnote = Font.footnote
        static let caption = Font.caption
        /// Timestamps, slide numbers, elapsed time. Always monospaced digits.
        static let mono = Font.system(.caption, design: .monospaced).monospacedDigit()
        static let monoBody = Font.system(.body, design: .monospaced).monospacedDigit()
        static let transcriptLineSpacing: CGFloat = 4
        static let summaryLineSpacing: CGFloat = 2
    }

    // MARK: Sizes of recurring glyphs
    enum Size {
        static let liveDot: CGFloat = 8
        static let liveDotSmall: CGFloat = 6
        static let slideThumb = CGSize(width: 96, height: 54)
        static let slideThumbLarge = CGSize(width: 128, height: 72)
        static let cardThumb = CGSize(width: 64, height: 36)
        static let levelMeterHeight: CGFloat = 6
    }
}

// MARK: - Color from hex

extension Color {
    /// Parses "#RRGGBB" or "RRGGBB".
    nonisolated init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

// MARK: - Environment: resolved animations

/// Animations resolved against Reduce Motion once at the root and injected for every
/// `withAnimation` call (DESIGN.md §6).
nonisolated struct DSAnimations: Sendable {
    let reduceMotion: Bool
    var settle: Animation { DS.Motion.resolve(DS.Motion.settle, reduceMotion: reduceMotion) }
    var quick: Animation { DS.Motion.resolve(DS.Motion.quick, reduceMotion: reduceMotion) }
    var float: Animation { DS.Motion.resolve(DS.Motion.float, reduceMotion: reduceMotion) }
    var morph: Animation { DS.Motion.morph }
    var numeric: Animation { DS.Motion.numeric }
    var hover: Animation { DS.Motion.hover }
}

extension EnvironmentValues {
    @Entry var dsAnimation = DSAnimations(reduceMotion: false)
}

extension View {
    /// Reads Reduce Motion once and injects `\.dsAnimation` for the subtree.
    func resolvingMotion() -> some View { modifier(MotionResolver()) }
}

private struct MotionResolver: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.environment(\.dsAnimation, DSAnimations(reduceMotion: reduceMotion))
    }
}

// MARK: - Shared view helpers

extension View {
    /// Opaque content card: `surface` fill + 1 pt hairline (never glass).
    func surfaceCard(radius: CGFloat = DS.Radius.card, raised: Bool = false, strokeColor: Color? = nil) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(raised ? DS.Colors.surfaceRaised : DS.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(strokeColor ?? DS.Colors.hairline, lineWidth: 1)
        )
    }

    /// Uppercase tracked column header per Appendix A.
    func columnHeaderStyle() -> some View {
        font(DS.Typo.caption)
            .fontWeight(.semibold)
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}

/// Makes a view's proposed size independent of its content (min 0, ideal ≈ 0) so the AppKit
/// column hosting views of NavigationSplitView / `.inspector` never see their size constants move
/// while text streams inside. Without this, streaming text can drive an AppKit
/// "Update Constraints in Window" loop.
struct SizeNeutral<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { _ in
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension ScrollViewProxy {
    /// Scrolls on the next run-loop turn. Scrolling synchronously from `onChange` /
    /// `onScrollGeometryChange` / `onAppear` can run inside AppKit layout and recurse into an
    /// "Update Constraints in Window" loop; deferring keeps scroll actions out of layout.
    @MainActor
    func scrollSoon(to id: some Hashable, anchor: UnitPoint? = nil, animation: Animation? = nil) {
        let proxy = self
        Task { @MainActor in
            await Task.yield()
            if let animation { withAnimation(animation) { proxy.scrollTo(id, anchor: anchor) } } else { proxy.scrollTo(id, anchor: anchor) }
        }
    }
}
