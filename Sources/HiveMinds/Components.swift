import SwiftUI

/// The OLED look: true black behind everything, with surfaces only just lifted off it.
enum Theme {
    static let background = Color.black
    static let surface = Color.white.opacity(0.045)
    static let hairline = Color.white.opacity(0.09)
}

/// One set of springs for the whole app, so everything moves with the same slightly bouncy feel.
/// Every animation here runs once in response to something; nothing loops while the app is idle.
enum Motion {
    /// Selection, tabs and things appearing: settles with a small overshoot.
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.68)
    /// Tiles making room while you drag: quick, a touch of bounce.
    static let reflow = Animation.spring(response: 0.3, dampingFraction: 0.72)
    /// A dropped tile springing into its slot.
    static let drop = Animation.spring(response: 0.45, dampingFraction: 0.6)
    /// The Canvas sliding to another page.
    static let pageTurn = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// Pressing a control.
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.6)
    /// Content coming in: a slight grow from just under full size, plus a fade.
    static let enter = AnyTransition.scale(scale: 0.97).combined(with: .opacity)
}

/// A plain button that squishes a little while pressed and springs back on release.
struct SquishButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.93

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == SquishButtonStyle {
    static var squish: SquishButtonStyle { SquishButtonStyle() }
}

struct StatusDot: View {
    let status: AgentStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(status == .asleep ? Color.clear : status.color)
            .overlay(Circle().strokeBorder(status.color.opacity(status == .asleep ? 0.6 : 0), lineWidth: 1.2))
            .frame(width: size, height: size)
            .background(
                Circle().fill(status.color.opacity(status == .needsYou ? 0.25 : 0)).frame(width: size * 2.2, height: size * 2.2)
            )
            // A single pop when the status changes, so a change catches the eye without anything looping.
            .phaseAnimator([1.0, 1.5, 1.0], trigger: status) { dot, scale in
                dot.scaleEffect(scale)
            } animation: { scale in
                scale > 1 ? .spring(response: 0.18, dampingFraction: 0.5) : Motion.bouncy
            }
            .animation(Motion.bouncy, value: status)
            .accessibilityLabel(status.label)
    }
}

struct StatusPill: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status, size: 7)
            Text(status.label).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassEffect(.regular.tint(status.color.opacity(status == .asleep ? 0 : 0.18)), in: .capsule)
    }
}

/// A quiet content card: a faint fill and a hairline edge. Glass stays on the controls layer.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

struct PageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 26, weight: .semibold))
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NoticeBar: View {
    let text: String
    var icon = "checkmark.circle"
    var tint = Color.green
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout).lineLimit(2)
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(14)
        // Clears itself after 10 seconds; a new notice restarts the timer.
        .task(id: text) {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { dismiss() }
        }
    }
}

extension Date {
    var relative: String {
        // A moment ago, or a hair in the future from clock jitter, reads "just now" rather than "in 0 seconds".
        let now = Date()
        if abs(timeIntervalSince(now)) < 5 { return "just now" }
        return RelativeDateTimeFormatter().localizedString(for: min(self, now), relativeTo: now)
    }
}
