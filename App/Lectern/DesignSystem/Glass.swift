import SwiftUI

/// Liquid Glass with an opaque fallback. Glass is used only for floating layers (DESIGN.md §3.1);
/// the fallback kicks in under Reduce Transparency and in the demo's `-flatGlass` mode (used for
/// automated screenshots, where backdrop-composited content can't be captured).
extension EnvironmentValues {
    @Entry var flatGlass = false
}

private struct LecternGlassModifier<S: Shape>: ViewModifier {
    var glass: Glass
    var shape: S
    @Environment(\.flatGlass) private var flat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if flat || reduceTransparency {
            content
                .background(shape.fill(DS.Colors.surfaceRaised))
                .overlay(shape.stroke(DS.Colors.hairline, lineWidth: 1))
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

private struct LecternProminentButton: ViewModifier {
    @Environment(\.flatGlass) private var flat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if flat || reduceTransparency { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.glassProminent) }
    }
}

extension View {
    /// `.glassEffect(_:in:)` with the opaque fallback.
    func lecternGlass(_ glass: Glass = .regular, in shape: some Shape) -> some View {
        modifier(LecternGlassModifier(glass: glass, shape: shape))
    }

    /// `.buttonStyle(.glassProminent)` with the opaque fallback.
    func lecternProminent() -> some View { modifier(LecternProminentButton()) }
}

/// `GlassEffectContainer` that degrades to a plain group in flat mode.
struct LecternGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content
    @Environment(\.flatGlass) private var flat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if flat || reduceTransparency {
            content()
        } else {
            GlassEffectContainer(spacing: spacing) { content() }
        }
    }
}
