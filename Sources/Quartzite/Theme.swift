#if canImport(SwiftUI)
import SwiftUI
import AppKit

/// One accent (the system accent), one corner radius, and a white schematic sheet
/// that matches Quartus' Block Editor in both light and dark mode.
enum Theme {
    static let radius: CGFloat = 6
    static let paper = Color.white
    static let ink = Color(red: 0.07, green: 0.08, blue: 0.10)
    static let inkMuted = Color(red: 0.42, green: 0.45, blue: 0.50)
    static let gridDot = Color(red: 0.62, green: 0.66, blue: 0.72)
    static let accent = Color.accentColor
    static let ok = Color.green
    static let warning = Color.orange
    static let error = Color.red

    // Block Editor colours, sampled from Quartus Prime 18 screenshots: black symbols,
    // purple captions and output leads, blue input leads and "VCC", teal dotted symbol
    // frames and a blue selection with square handles.
    static let qPurple = Color(red: 0.50, green: 0.0, blue: 0.50)
    static let qBlue = Color(red: 0.0, green: 0.0, blue: 0.85)
    static let qFrame = Color(red: 0.25, green: 0.62, blue: 0.70)
    static let qSelect = Color(red: 0.0, green: 0.27, blue: 0.95)
    static let qGridDot = Color(red: 0.28, green: 0.28, blue: 0.30)
    static let qLocation = Color(red: 0.20, green: 0.42, blue: 0.62)

    /// 8-unit dot grid tile (one dot per grid point), tiled by the canvas.
    static let quartusGridTile: Image = {
        let size = NSSize(width: 8, height: 8)
        let img = NSImage(size: size, flipped: true) { _ in
            NSColor(red: 0.28, green: 0.28, blue: 0.30, alpha: 0.85).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1.1, height: 1.1)).fill()
            return true
        }
        return Image(nsImage: img)
    }()

    /// 16-unit dot grid tile, drawn once and tiled by the canvas.
    static let gridTile: Image = {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size, flipped: true) { _ in
            NSColor(red: 0.62, green: 0.66, blue: 0.72, alpha: 0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 1.4, height: 1.4)).fill()
            return true
        }
        return Image(nsImage: img)
    }()
}

/// Status glyph used by the Tasks pane and the report.
struct TaskStatusIcon: View {
    var state: TaskState
    var body: some View {
        switch state {
        case .notRun: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.error)
        }
    }
}

/// Compact icon button used in the editor tool strips.
struct StripButton<Icon: View>: View {
    var help: String
    var active = false
    var action: () -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        Button(action: action) {
            icon()
                .frame(width: 26, height: 22)
                .background(active ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(active ? Theme.accent.opacity(0.6) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(Text(help.components(separatedBy: " (").first ?? help))
    }
}
#endif
