import SwiftUI
import TerminalBridgeKit

/// Test Mode chips above the composer, grouped by section. A tap sends the question like a typed message.
struct TestModePanel: View {
    @ObservedObject var chat: TerminalChatViewModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var includeReplies = true
    @State private var includeSafetyReplies = false
    @State private var pendingShare: SharedExport?

    var body: some View {
        let session = chat.testSession
        VStack(alignment: .leading, spacing: 4) {
            header(session)
            ClaudeJudgeSendRefusal(scope: TerminalChatViewModel.testJudgeScope,
                                   identifier: "terminal.testMode.judgeWithClaude")
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(TestModeSection.allCases, id: \.self) { group in
                        let shown = session.shownQuestions.filter { $0.group == group }
                        if !shown.isEmpty {
                            Text(verbatim: group.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, group == TestModeSection.allCases.first ? 0 : 6)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(shown) { question in
                                chip(question)
                            }
                        }
                    }
                    if !session.hasSendableLeft {
                        Text("No quedan preguntas.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollIndicators(.hidden)
            if let blocked = session.shownQuestions.first(where: { !$0.isSendable }),
               let reason = blocked.unavailableReason {
                Text(verbatim: "\(blocked.id): \(reason).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.testMode.panel")
        // Test Mode files can hold Seguridad answers: none outlives the panel.
        .onAppear(perform: ExportDirectory.clear)
        .onDisappear(perform: ExportDirectory.clear)
        .exportShareSheet($pendingShare)
    }

    /// Stacked at accessibility sizes so the score and the reset button are not squeezed off the row.
    private func header(_ session: TestModeSession) -> some View {
        let isLarge = typeSize.isAccessibilitySize
        let layout = isLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Label("Modo Test", systemImage: SettingsMenuEntry.testMode.symbol)
                .font(.caption.weight(.semibold))
            Text(verbatim: session.scoreText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("terminal.testMode.score")
            if !isLarge { Spacer(minLength: 0) }
            ClaudeJudgeControls(
                scope: TerminalChatViewModel.testJudgeScope, subjects: { chat.testJudgeSubjects },
                count: chat.testJudgeSubjects.count, identifier: "terminal.testMode.judgeWithClaude", compact: true
            ) { item, judgment in
                chat.recordTestSecondOpinion(judgment, key: item.key, judgedAnswer: item.subject.answer)
            }
            .font(.caption)
            exportMenu(session)
            // A grade still arriving would count a question the reset just put back.
            Button(action: chat.resetTestQuestions) {
                Text("Reiniciar preguntas")
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .disabled(chat.isBusy)
            .accessibilityIdentifier("terminal.testMode.reset")
        }
    }

    /// The session's own questions, grades and answers as a Markdown file; never the chat entries.
    private func exportMenu(_ session: TestModeSession) -> some View {
        Menu {
            Toggle(CapabilityText.includeReplies, isOn: $includeReplies)
                .menuActionDismissBehavior(.disabled)
            Toggle(CapabilityText.includeSafetyReplies, isOn: $includeSafetyReplies)
                .menuActionDismissBehavior(.disabled)
                .disabled(!includeReplies)
            Button {
                // Read at tap time: the session and the toggles may have changed since the menu opened.
                let options = CapabilityExportOptions(includeReplies: includeReplies,
                                                      includeSafetyReplies: includeReplies && includeSafetyReplies,
                                                      appVersion: ExportDirectory.appVersion)
                let file = ExportFile.testSession(chat.testSession, modelTitle: chat.selectedChoice?.title ?? "",
                                                  options: options)
                pendingShare = try? file.write()
            } label: {
                Label(CapabilityText.exportTestSession, systemImage: "doc.plaintext")
            }
            if includeReplies {
                Text(verbatim: CapabilityText.exportMenuWarning)
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .font(.caption)
        .disabled(session.results.isEmpty || chat.isBusy)
        .accessibilityLabel(Text(verbatim: CapabilityText.exportTestSession))
        .accessibilityIdentifier("terminal.testMode.export")
    }

    private static let sendHint = "Envía la pregunta al modelo y la quita de la lista."
    /// The bordered capsule adds its own padding around this, reaching the 44 pt hit target.
    private static let chipLabelHeight: CGFloat = 36

    private var canSend: Bool {
        chat.selectedChoice != nil && !chat.isBusy && !chat.isRunningCapabilityTests
    }

    private func chip(_ question: TestModeQuestion) -> some View {
        Button {
            chat.sendTestQuestion(question.id)
        } label: {
            Text(verbatim: question.chipTitle)
                .font(.caption)
                .lineLimit(1)
                .frame(minHeight: Self.chipLabelHeight)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(!question.isSendable || !canSend)
        .accessibilityHint(Text(verbatim: question.unavailableReason ?? Self.sendHint))
        .accessibilityIdentifier("terminal.testMode.question.\(question.id)")
    }
}

/// The grade under a Test Mode reply: icon and words, never colour alone. A reply still in the current score also
/// gets the owner's override buttons; they change the score only, never what is sent, copied or typed.
struct TestGradeRow: View {
    let outcome: TestModeOutcome
    let identifier: String
    var secondOpinion: ClaudeJudgment?
    /// Why the last «Evaluar con Claude» gave no judgment for this reply.
    var judgeNote: String?
    /// Nil for a reply a reset or a model change left out of the score.
    var onAction: ((TestModeOverrideAction) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: outcome.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = outcome.automaticNote {
                        Text(verbatim: note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: outcome.symbol)
                    .foregroundStyle(tint)
            }
            .font(.footnote.weight(.semibold))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
            secondOpinionRow
            if let onAction, !outcome.actions.isEmpty {
                HStack(spacing: 8) {
                    // Deshacer sits at the other edge, so a double tap on a mark button cannot reach it.
                    if outcome.verdict != nil {
                        Spacer(minLength: 0)
                    }
                    ForEach(outcome.actions, id: \.self) { action in
                        Button {
                            onAction(action)
                        } label: {
                            Text(verbatim: action.title)
                                .font(.caption)
                                .frame(minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier(identifier + "." + action.identifier)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var secondOpinionRow: some View {
        if let line = secondOpinion?.text ?? judgeNote {
            Text(verbatim: line)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(identifier + ".secondOpinion")
        }
        if let onAction, let secondOpinion, let action = outcome.action(applying: secondOpinion) {
            Button {
                onAction(action)
            } label: {
                Text(verbatim: ClaudeJudgeText.apply + ": " + action.title)
                    .font(.caption)
                    .frame(minHeight: 36)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier(identifier + ".applySecondOpinion")
        }
    }

    private var tint: Color {
        switch outcome.verdict {
        case .validated: return .teal
        case .rejected: return .pink
        case nil: break
        }
        switch outcome.automatic {
        case .correct: return .green
        case .incorrect: return .red
        case .review: return .orange
        case .notApplicable: return .secondary
        }
    }
}
