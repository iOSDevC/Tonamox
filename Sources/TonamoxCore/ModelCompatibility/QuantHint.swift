import Foundation

/// Plain-language meaning of a GGUF quantization token, for people who do not know what `Q4_K_M` is.
public enum QuantHint {

    /// `balanced, common default` for `Q4_K_M`; `nil` for a token it does not know.
    public static func text(for label: String) -> String? {
        let token = label.uppercased()
        if ["F32", "F16", "BF16", "FP16", "FP32"].contains(token) { return "unquantized, full size" }
        if token == "Q4_K_M" { return "balanced, common default" }
        switch bits(of: token) {
        case 8?: return "near-lossless, large"
        case 6?: return "very high quality, large"
        case 5?: return "high quality, larger"
        case 4?: return "balanced, a little smaller"
        case 3?: return "small, lower quality"
        case 1?, 2?: return "smallest, lowest quality"
        default: return nil
        }
    }

    /// The bit width in `Q5_K_S`, `IQ3_XXS`, `TQ1_0`, `MXFP4`.
    private static func bits(of token: String) -> Int? {
        let digits: Substring
        if token.hasPrefix("MXFP") {
            digits = token.dropFirst(4)
        } else if token.hasPrefix("IQ") || token.hasPrefix("TQ") {
            digits = token.dropFirst(2)
        } else if token.hasPrefix("Q") {
            digits = token.dropFirst()
        } else {
            return nil
        }
        return digits.first?.wholeNumberValue
    }
}
