import SwiftUI
import UIKit

/// Shows a line exactly as it would be typed: wraps at any character and never adds a hyphen.
/// SwiftUI `Text` hyphenates long tokens (a path rendered "458da88e-" / "f20f"), which misstates the command.
struct VerbatimCommandText: UIViewRepresentable {
    let text: String
    var isSecondary = false

    private static let calloutSize: CGFloat = 16

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let font = UIFontMetrics(forTextStyle: .callout).scaledFont(
            for: .monospacedSystemFont(ofSize: Self.calloutSize, weight: .regular),
            compatibleWith: view.traitCollection
        )
        view.attributedText = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: isSecondary ? UIColor.secondaryLabel : UIColor.label,
            .paragraphStyle: Self.paragraph,
            .accessibilitySpeechPunctuation: true,
        ])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.hyphenationFactor = 0
        style.usesDefaultHyphenation = false
        return style
    }()
}
