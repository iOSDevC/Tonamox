import SwiftUI
import TerminalBridgeKit

/// A reply's leading reasoning, kept apart from its answer: never parsed for commands, never sent back to a model.
struct ReplyReasoning: Equatable {
    /// Keys the block's expanded state; the same while streaming and once the reply is in the transcript.
    let id: UUID
    var text: String
    /// Measured on `ContinuousClock` from the first chunk to the end of the last leading block; nil while the model
    /// is still reasoning.
    var duration: Duration?
    /// The turn ended inside the reasoning on its own (the token limit), so there is no answer.
    var endedWithoutAnswer = false
    /// A stop or an error ended the turn inside the reasoning: the duration is not a finished one.
    var wasInterrupted = false
    /// The reasoning budget closed the block for the model.
    var wasCut = false

    var isLive: Bool { duration == nil && !wasInterrupted }

    var header: String {
        if wasInterrupted { return ReasoningText.interrupted }
        guard let duration else { return ReasoningText.live }
        return wasCut ? ReasoningText.header(cutAfter: duration) : ReasoningText.header(thoughtFor: duration)
    }
}

/// Collapsed by default; the header is the only control. Expanded, the text is selectable and dimmer, with a rule.
struct ReasoningBlockView: View {
    let reasoning: ReplyReasoning
    @Binding var isExpanded: Bool
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if reasoning.isLive {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(verbatim: reasoning.header)
                        .font(.subheadline)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: reasoning.header))
            .accessibilityValue(Text(verbatim: isExpanded ? ReasoningText.expandedValue : ReasoningText.collapsedValue))
            .accessibilityHint(Text(verbatim: isExpanded ? ReasoningText.collapseHint : ReasoningText.expandHint))
            .accessibilityIdentifier(identifier)
            if isExpanded {
                Text(verbatim: ReasoningText.shown(reasoning.text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(.tertiary)
                            .frame(width: 3)
                            .accessibilityHidden(true)
                    }
                    .accessibilityIdentifier(identifier + ".text")
            }
            if reasoning.endedWithoutAnswer {
                Label {
                    Text(verbatim: ReasoningText.unfinishedNote)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier + ".unfinished")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
