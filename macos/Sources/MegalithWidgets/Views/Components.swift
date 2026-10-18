import AppKit
import SwiftUI

struct WindowDragHandle: NSViewRepresentable {
    var enabled: Bool

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DragView else { return }
        view.enabled = enabled
        view.window?.invalidateCursorRects(for: view)
    }

    private final class DragView: NSView {
        var enabled = false
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            if enabled { (window as? WidgetPanel)?.drag(with: event) }
        }

        override func resetCursorRects() {
            if enabled {
                addCursorRect(bounds, cursor: .openHand)
            }
        }
    }
}

/// Every view reads its colors through this so light/dark switch together.
struct Themed<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: (Palette) -> Content

    var body: some View {
        content(Palette.current(scheme))
    }
}

/// A 26pt square toolbar button, muted until hovered, like Zed's.
struct IconButton: View {
    let icon: String
    let help: String
    var tint: Color?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Themed { p in
            Button(action: action) {
                Icon(icon)
                    .foregroundStyle(tint ?? (hovering ? p.text : p.muted))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? p.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in withAnimation(.easeOut(duration: 0.14)) { self.hovering = hovering } }
            .help(help)
        }
    }
}

/// Linked choices with a selection pill that slides between them.
struct Segmented<Value: Hashable, Label: View>: View {
    let options: [Value]
    @Binding var selection: Value
    @ViewBuilder let label: (Value) -> Label

    @Namespace private var pill

    var body: some View {
        Themed { p in
            HStack(spacing: 0) {
                ForEach(options, id: \.self) { option in
                    let selected = option == selection
                    Button {
                        withAnimation(.snappy(duration: 0.22)) { selection = option }
                    } label: {
                        label(option)
                            .font(Fonts.ui(12, .medium))
                            .foregroundStyle(selected ? p.text : p.muted)
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(p.bg)
                                        .shadow(color: p.shadow, radius: 1, y: 1)
                                        .matchedGeometryEffect(id: "pill", in: pill)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(p.hover))
        }
    }
}

/// Centered icon, title and message for empty, no-match and error states.
struct StateView: View {
    let icon: String
    let tone: Color?
    let title: String
    let message: String

    @State private var shown = false

    var body: some View {
        Themed { p in
            VStack(spacing: 0) {
                Icon(icon, size: 22)
                    .foregroundStyle(tone ?? p.muted)
                    .padding(.bottom, 10)
                Text(title)
                    .font(Fonts.ui(13, .semibold))
                Text(message)
                    .font(Fonts.ui(12))
                    .foregroundStyle(p.muted)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.top, 3)
                    .frame(maxWidth: 420)
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                withAnimation(.spring(duration: 0.42, bounce: 0)) { shown = true }
            }
        }
    }
}

/// Row-shaped stand-ins while the first load is in flight.
struct PlaceholderList: View {
    private static let titleWidths: [CGFloat] = [260, 190, 230, 150, 210]

    @State private var bright = false

    var body: some View {
        Themed { p in
            VStack(spacing: 0) {
                ForEach(0..<Layout.visibleRows, id: \.self) { index in
                    HStack(spacing: 10) {
                        Circle().frame(width: 14, height: 14)
                        Capsule().frame(width: Self.titleWidths[index % 5], height: 9)
                        Spacer(minLength: 0)
                        Capsule().frame(width: 90, height: 9)
                        Capsule().frame(width: 56, height: 9)
                    }
                    .foregroundStyle(p.hover)
                    .padding(.horizontal, 10)
                    .frame(height: Layout.rowHeight)
                    .opacity(bright ? 1 : 0.4)
                    .animation(
                        .easeInOut(duration: 1.1).repeatForever().delay(Double(index % 5) * 0.12),
                        value: bright
                    )
                }
            }
            .padding(6)
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear { bright = true }
        }
    }
}

struct ToastView: View {
    let toast: Toast
    let undo: () -> Void

    var body: some View {
        Themed { p in
            HStack(spacing: 10) {
                Text(toast.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 380)
                Button("Undo", action: undo)
                    .buttonStyle(.plain)
                    .font(Fonts.ui(12, .medium))
                    .foregroundStyle(p.accent)
            }
            .font(Fonts.ui(12))
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(p.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(p.border.opacity(0.9)))
            .shadow(color: p.shadow, radius: 9, y: 6)
        }
    }
}
