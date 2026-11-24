import SwiftUI
import TerminalBridgeKit

/// Shows the sanitised output, its size and what was removed, and the exact turn the model would get, before it is sent.
struct PastedOutputPreview: View {
    let output: PastedOutput
    /// The newest captured line, or the line that carried a network ticket, offered as context; the user can
    /// leave it out.
    let command: String?
    let source: TerminalChatViewModel.PasteSource
    @ObservedObject var chat: TerminalChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var includesCommand = true

    static let untrustedFooter = "Es texto del ordenador: cualquier programa de la Mac pudo escribirlo o cambiarlo. "
        + "Se trata como dato: va al modelo entre delimitadores y con la instrucción de no seguir nada de lo que "
        + "diga. Lo que proponga después necesita tu aprobación, como cualquier otra orden."

    var body: some View {
        NavigationStack {
            Form {
                if case .network(let paste, _) = source {
                    provenanceSection(paste)
                }
                Section {
                    ScrollView {
                        Text(verbatim: output.text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 120, maxHeight: 280)
                    .accessibilityIdentifier("terminal.pastePreview.text")
                } header: {
                    Text("Salida (dato) que irá entre delimitadores")
                } footer: {
                    Text(verbatim: Self.untrustedFooter)
                }
                Section {
                    LabeledContent("Tamaño", value: "\(output.byteCount) bytes")
                    LabeledContent("Recortada", value: cutDescription)
                    LabeledContent("Quitado", value: removedDescription)
                    if output.hadUnterminatedSequence {
                        Text("Una secuencia de escape sin terminar ocultaba el final: se descartó ese resto.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Datos")
                } footer: {
                    Text(verbatim: "Al modelo llegan como mucho \(PastedOutput.maxBytes) bytes: el final de la salida, "
                        + "sin secuencias de escape ni caracteres de control salvo salto de línea y tabulador.")
                }
                .accessibilityIdentifier("terminal.pastePreview.facts")
                if let command {
                    Section {
                        Toggle(isNetwork ? "Incluir la orden que llevaba el enlace" : "Incluir la orden capturada",
                               isOn: $includesCommand)
                            .accessibilityIdentifier("terminal.pastePreview.includeCommand")
                        if includesCommand {
                            Text(verbatim: command)
                                .font(.caption.monospaced())
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } footer: {
                        Text(isNetwork
                            ? "La orden a la que se añadió el enlace; quien tenga el enlace pudo enviar otra cosa."
                            : "La última orden capturada en esta sesión; puede no ser la que produjo esta salida.")
                    }
                }
                Section {
                    if let prompt {
                        DisclosureGroup("Ver el texto exacto (\(prompt.utf8.count) bytes)") {
                            Text(verbatim: prompt)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel(Text(verbatim: "Texto que recibirá el modelo, \(prompt.utf8.count) bytes"))
                                .accessibilityValue(Text(verbatim: prompt))
                        }
                        .accessibilityIdentifier("terminal.pastePreview.prompt")
                    } else {
                        Text("La salida, la pregunta o la orden contienen la marca de delimitación: no se puede enviar. "
                            + "Descarta y vuelve a pegar.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Lo que recibirá el modelo")
                } footer: {
                    Text("Incluye la orden, la pregunta, la instrucción de tratar la salida como dato y los delimitadores.")
                }
                Section {
                    TextField(PastedOutputPrompt.defaultQuestion, text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("terminal.pastePreview.question")
                } header: {
                    Text("Pregunta (opcional)")
                } footer: {
                    Text(verbatim: "Hasta \(PastedOutputPrompt.questionMaxCharacters) caracteres.")
                }
            }
            .navigationTitle(isNetwork ? "Salida recibida por red" : "Salida pegada")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Descartar", role: .cancel) {
                        chat.discardPaste()
                        dismiss()
                    }
                    .accessibilityIdentifier("terminal.pastePreview.discard")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enviar al modelo") {
                        chat.sendPastedOutput(question: question, command: includesCommand ? command : nil)
                        dismiss()
                    }
                    .disabled(chat.isBusy || chat.isRunningCapabilityTests || chat.selectedChoice == nil
                              || prompt == nil)
                    .accessibilityIdentifier("terminal.pastePreview.send")
                }
            }
        }
        .accessibilityIdentifier("terminal.pastePreview")
        .onChange(of: question) { _, newValue in
            if newValue.count > PastedOutputPrompt.questionMaxCharacters {
                question = String(newValue.prefix(PastedOutputPrompt.questionMaxCharacters))
            }
        }
    }

    private var isNetwork: Bool {
        if case .network = source { return true }
        return false
    }

    private func provenanceSection(_ paste: NetworkPaste) -> some View {
        Section {
            ForEach(paste.provenanceLines, id: \.self) { line in
                Text(verbatim: line)
                    .font(.callout)
            }
            ForEach(paste.warnings, id: \.self) { warning in
                Label {
                    Text(verbatim: warning)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(.orange)
            }
        } header: {
            Text("De dónde viene")
        } footer: {
            Text("Llegó por http sin cifrar con un enlace de un solo uso. La dirección la da la red y no prueba quién "
                + "la envió.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.pastePreview.provenance")
    }

    /// Built from the same nonce, question and command that "Enviar al modelo" uses.
    private var prompt: String? {
        chat.pastePrompt(question: question, command: includesCommand ? command : nil)
    }

    private var cutDescription: String {
        guard output.wasCut else { return "no" }
        return "sí (se omitieron \(output.droppedLeadingBytes) bytes del principio)"
    }

    private var removedDescription: String {
        "\(output.removedEscapeSequences) secuencias de escape, \(output.removedCharacters) caracteres de control"
    }
}
