import SwiftUI
import TerminalBridgeKit

/// A line exactly as it would be sent, with its icon buttons at the top-trailing edge. At accessibility text
/// sizes, or when the text would get too narrow, the buttons move below so they never cover the command.
struct CommandCodeRow<Trailing: View>: View {
    let text: String
    var isSecondary = false
    let textIdentifier: String
    /// Below zero in the plain row, so VoiceOver reads the warnings under the line before its buttons.
    var buttonsSortPriority: Double = 0
    @ViewBuilder let buttons: Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Narrower than this and a typical command wraps every few characters.
    private static var minTextWidth: CGFloat { 140 }

    var body: some View {
        if typeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                sideBySide
                stacked
            }
        }
    }

    private var sideBySide: some View {
        HStack(alignment: .top, spacing: 4) {
            // The ideal width is what ViewThatFits measures; the text still takes all the room left.
            VerbatimCommandText(text: text, isSecondary: isSecondary)
                .frame(minWidth: Self.minTextWidth, idealWidth: Self.minTextWidth, maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(textIdentifier)
            buttonCluster
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 4) {
            VerbatimCommandText(text: text, isSecondary: isSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(textIdentifier)
            buttonCluster
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var buttonCluster: some View {
        HStack(spacing: 0) { buttons }
            .accessibilityElement(children: .contain)
            .accessibilitySortPriority(buttonsSortPriority)
    }
}

/// A borderless 44 pt icon button: a spinner while in flight, a brief checkmark after a success.
struct CommandIconButton: View {
    let symbol: String
    let label: String
    var hint = ""
    var isInFlight = false
    /// A new non-nil value marks a fresh success.
    var successID: UUID?
    /// Posted to VoiceOver on a fresh success.
    var announcement: String?
    var role: ButtonRole?
    let action: () -> Void

    @State private var flashing: UUID?

    var body: some View {
        Button(role: role, action: action) {
            icon
                .font(.body)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityHint(Text(verbatim: hint))
        // onChange, not task(id:): a row scrolled back into view must not flash an old success.
        .onChange(of: successID) { _, newValue in
            guard let newValue else { return }
            flashing = newValue
            if let announcement {
                AccessibilityNotification.Announcement(announcement).post()
            }
        }
        .task(id: flashing) {
            guard flashing != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { flashing = nil }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if isInFlight {
            ProgressView()
        } else if flashing != nil {
            Image(systemName: CommandRowActions.successSymbol)
                .foregroundStyle(.green)
        } else {
            Image(systemName: symbol)
        }
    }
}
