import SwiftUI

// MARK: - JumpToLivePill

struct JumpToLivePill: View {
    var newCount: Int
    var label: String = "Jump to live"
    var symbol: String = "arrow.down"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: symbol)
                Text(label)
                if newCount > 1 {
                    Text("\(newCount) new")
                        .font(DS.Typo.caption)
                        .padding(.horizontal, DS.Space.xs)
                        .padding(.vertical, 1)
                        .background(DS.Colors.accent.opacity(0.15), in: Capsule())
                }
            }
            .font(DS.Typo.subheadline.weight(.medium))
            .padding(.horizontal, DS.Space.m)
            .frame(height: 28)
        }
        .buttonStyle(.plain)
        .lecternGlass(.regular.interactive(), in: .capsule)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityLabel(newCount > 1 ? "\(label), \(newCount) new" : label)
    }
}

// MARK: - NoticeBanner

struct NoticeBanner: View {
    var notice: Notice
    var action: (() -> Void)? = nil
    var onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: notice.symbol)
                .foregroundStyle(notice.kind == .warning ? DS.Colors.warning : DS.Colors.accent)
            Text(notice.title).font(DS.Typo.subheadline).lineLimit(1)
            Spacer(minLength: DS.Space.s)
            if let label = notice.actionLabel, let action {
                Button(label, action: action).buttonStyle(.link).font(DS.Typo.subheadline)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: 36)
        .lecternGlass(.regular, in: .rect(cornerRadius: DS.Radius.float))
        .onHover { hovered = $0 }
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - EmptyStateView

struct EmptyStateView: View {
    enum Style { case full, compact }
    var symbol: String
    var title: String
    var message: String? = nil
    var action: (label: String, handler: () -> Void)? = nil
    var style: Style = .full
    var useLecternGlyph = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathed = false

    var body: some View {
        VStack(spacing: style == .full ? DS.Space.m : DS.Space.s) {
            Group {
                if useLecternGlyph {
                    LecternGlyphView(size: style == .full ? 48 : 24)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: style == .full ? 48 : 24, weight: .regular))
                        .symbolEffect(.breathe, options: .nonRepeating, isActive: !reduceMotion && !breathed)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.bottom, DS.Space.xs)
            Text(title).font(style == .full ? DS.Typo.title2 : DS.Typo.headline)
            if let message {
                Text(message)
                    .font(style == .full ? DS.Typo.body : DS.Typo.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if let action {
                if style == .full {
                    Button(action.label, action: action.handler)
                        .lecternProminent()
                        .padding(.top, DS.Space.s)
                } else {
                    Button(action.label, action: action.handler).buttonStyle(.borderless).font(DS.Typo.footnote)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.xxl)
        .onAppear { Task { try? await Task.sleep(for: .seconds(2)); breathed = true } }
    }
}

// MARK: - Flow layout

/// Minimal wrapping layout for chip rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = DS.Space.s

    nonisolated func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : maxX, height: y + rowHeight)
    }

    nonisolated func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
