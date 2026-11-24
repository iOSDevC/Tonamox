import SwiftUI
import TerminalBridgeKit
import TonamoxCore
import TonamoxUI

/// «Modificado: sin filtros de seguridad», or «Sin filtros» where a row has no room.
struct SafetyFiltersMark: View {
    var isShort = false

    var body: some View {
        Label(isShort ? ModifiedModelHeuristic.shortLabel : ModifiedModelHeuristic.label,
              systemImage: ModifiedModelHeuristic.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Text(verbatim: ModifiedModelHeuristic.label))
    }

    /// For the Hugging Face search and repo page, which TonamoxUI draws without knowing the heuristic. Tags count:
    /// Hugging Face marks adult content with ``ModifiedModelHeuristic/adultContentTag``.
    static let repoCaution = HFRepoCaution(id: "tonamox.terminal.safety-filters") { repoID, tags in
        ModifiedModelHeuristic.applies(repoID: repoID, tags: tags) ? ModifiedModelHeuristic.label : nil
    }

    /// GGUF file names of catalogue entries flagged `Model.isUncensored`. `Model.textModels` leaves those entries
    /// out, so a downloaded one reaches the picker only as a file, whose name may carry no term (Dolphin 3.0).
    static func flaggedCatalogueFiles() -> Set<String> {
        Set(Model.allModels.filter(\.isUncensored).compactMap(\.ggufFilename))
    }
}
