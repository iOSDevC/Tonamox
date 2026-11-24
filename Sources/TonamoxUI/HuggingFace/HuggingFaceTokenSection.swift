import SwiftUI
import TonamoxCore

/// The Hugging Face read token for gated repos, kept in the Keychain where every Tonamox downloader reads it.
/// Two `Form` sections; place it inside your own `Form`.
public struct HuggingFaceTokenSection: View {
    @State private var draft = ""
    @State private var hasToken = KeychainDownloadAuth.hasHuggingFaceToken
    @State private var notice: String?

    public init() {}

    public var body: some View {
        Section {
            LabeledContent(String(localized: "Status", bundle: .module),
                           value: hasToken ? String(localized: "Token saved", bundle: .module)
                               : String(localized: "No token", bundle: .module))
            SecureField("hf_…", text: $draft)
                .textContentType(.password)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button(String(localized: "Save token", bundle: .module), systemImage: "key") { save() }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if hasToken {
                Button(String(localized: "Remove token", bundle: .module), systemImage: "trash", role: .destructive) { remove() }
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Hugging Face token", bundle: .module)
        } footer: {
            Text("""
                Needed only for gated or private repos: accept the license on the repo page first, then create a \
                read token. GGUF and MLX downloads and the compatibility check send it to huggingface.co only. \
                Stored in the Keychain on this device and never synced. Apps that share Tonamox storage through \
                an App Group read the same token. Search stays anonymous, so private repos don't appear in results.
                """, bundle: .module)
        }
        .onAppear { hasToken = KeychainDownloadAuth.hasHuggingFaceToken }
        Section {
            if let tokens = URL(string: "https://huggingface.co/settings/tokens") {
                Link(String(localized: "Create a read token on huggingface.co", bundle: .module), destination: tokens)
            }
        }
    }

    private func save() {
        do {
            try KeychainDownloadAuth.saveHuggingFaceToken(draft)
            draft = ""
            notice = String(localized: "Saved. Downloads and checks now send it to huggingface.co only.", bundle: .module)
        } catch {
            notice = String(localized: "Could not save: \(error.localizedDescription)", bundle: .module)
        }
        hasToken = KeychainDownloadAuth.hasHuggingFaceToken
    }

    private func remove() {
        KeychainDownloadAuth.deleteHuggingFaceToken()
        hasToken = KeychainDownloadAuth.hasHuggingFaceToken
        notice = String(localized: "Removed.", bundle: .module)
    }
}

/// The token section in a sheet, opened from a gated error or the detail's key button.
struct HFTokenSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { HuggingFaceTokenSection() }
                .formStyle(.grouped)
                .navigationTitle(Text("Hugging Face token", bundle: .module))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done", bundle: .module)) { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #endif
    }
}
