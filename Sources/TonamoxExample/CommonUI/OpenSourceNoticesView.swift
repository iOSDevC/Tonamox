import SwiftUI

/// One component of `THIRD_PARTY_NOTICES.md`, the bundled copy of the repository file.
struct ThirdPartyNotice: Identifiable, Hashable, Sendable {
    struct LicenseText: Hashable, Sendable {
        let label: String
        let body: String
    }

    var id: String { name }
    let name: String
    let version: String
    let licenseID: String
    let source: URL?
    let includedIn: String
    let texts: [LicenseText]
}

/// Parses the "## Components" part of the notices file: `### name`, `- Key: value` lines, `#### file` labels and
/// fenced licence texts. Everything outside that part (header, counsel questions) is for the repository reader.
enum ThirdPartyNotices {
    static let resourceName = "THIRD_PARTY_NOTICES"

    static let bundled: [ThirdPartyNotice] = {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(markdown)
    }()

    static func parse(_ markdown: String) -> [ThirdPartyNotice] {
        var builder = Builder()
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            builder.consume(line)
        }
        builder.finishComponent()
        return builder.notices
    }

    private struct Builder {
        private(set) var notices: [ThirdPartyNotice] = []
        private var inComponents = false
        private var name: String?
        private var fields: [String: String] = [:]
        private var texts: [ThirdPartyNotice.LicenseText] = []
        private var pendingLabel: String?
        private var fenceLines: [Substring]?

        mutating func consume(_ line: Substring) {
            if fenceLines != nil {
                consumeFenced(line)
            } else if line.hasPrefix("## ") {
                finishComponent()
                inComponents = line == "## Components"
            } else if !inComponents {
                return
            } else if line.hasPrefix("### ") {
                finishComponent()
                name = String(line.dropFirst(4))
            } else if line.hasPrefix("#### ") {
                pendingLabel = String(line.dropFirst(5))
            } else if line.hasPrefix("```") {
                fenceLines = []
            } else if line.hasPrefix("- "), let colon = line.firstIndex(of: ":") {
                let key = line[line.index(line.startIndex, offsetBy: 2)..<colon]
                fields[String(key), default: ""] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }

        private mutating func consumeFenced(_ line: Substring) {
            guard line == "```" else {
                fenceLines?.append(line)
                return
            }
            let body = (fenceLines ?? []).joined(separator: "\n")
            texts.append(ThirdPartyNotice.LicenseText(label: pendingLabel ?? "Licencia", body: body))
            fenceLines = nil
            pendingLabel = nil
        }

        mutating func finishComponent() {
            defer {
                name = nil
                fields = [:]
                texts = []
                pendingLabel = nil
            }
            guard let name else { return }
            notices.append(ThirdPartyNotice(
                name: name,
                version: fields["Version"].map(Self.plain) ?? "",
                licenseID: fields["License"] ?? "",
                source: fields["Source"].flatMap(URL.init(string:)),
                includedIn: fields["Included in"].map(Self.plain) ?? "",
                texts: texts
            ))
        }

        /// Drops the Markdown code ticks the repository file uses around identifiers.
        private static func plain(_ value: String) -> String {
            value.replacingOccurrences(of: "`", with: "")
        }
    }
}

/// "Código abierto y licencias": the bundled notices, readable offline. Push it onto an existing navigation stack.
struct OpenSourceNoticesView: View {
    private let notices = ThirdPartyNotices.bundled

    var body: some View {
        List {
            Section {
                Text("Esta app usa componentes de código abierto. Toca uno para leer su licencia completa; el texto se puede seleccionar y copiar. Todo está incluido en la app y no necesita conexión.")
            }
            Section("Modelos") {
                Text("Los modelos (GGUF, MLX, Core ML) se descargan por separado y no forman parte de la app. Cada uno tiene su propia licencia, que puede limitar algunos usos: consúltala en su ficha de Hugging Face antes de usarlo o compartirlo. En el buscador de Hugging Face, la ficha de cada repositorio muestra, en su apartado de licencia, la que declara el repositorio.")
            }
            Section("Componentes") {
                if notices.isEmpty {
                    Text("No se encontraron los avisos de terceros en esta compilación.")
                        .foregroundStyle(.secondary)
                }
                ForEach(notices) { notice in
                    NavigationLink {
                        OpenSourceNoticeDetailView(notice: notice)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notice.name)
                            Text("\(notice.version) · \(notice.licenseID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("notices.row.\(notice.name)")
                }
            }
        }
        .navigationTitle("Código abierto y licencias")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("notices.list")
    }
}

struct OpenSourceNoticeDetailView: View {
    let notice: ThirdPartyNotice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Versión", value: notice.version)
                    LabeledContent("Licencia", value: notice.licenseID)
                    if !notice.includedIn.isEmpty {
                        LabeledContent("Uso", value: notice.includedIn)
                    }
                    if let source = notice.source {
                        Link("Código fuente", destination: source)
                    }
                }
                ForEach(notice.texts, id: \.self) { text in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(text.label)
                            .font(.headline)
                        Text(text.body)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(notice.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// Tab root for apps whose settings tab cannot host a push: a stack of its own around the list.
struct OpenSourceNoticesTab: View {
    var body: some View {
        NavigationStack {
            OpenSourceNoticesView()
        }
    }
}

#if os(macOS)
/// Settings window of the Mac apps: the shared hybrid settings plus the notices.
struct AppSettingsWindow: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                HybridSettingsView(isEmbedded: true)
            }
            Tab("Licencias", systemImage: "doc.text") {
                OpenSourceNoticesTab()
                    .frame(minWidth: 520, minHeight: 420)
            }
        }
    }
}
#endif
