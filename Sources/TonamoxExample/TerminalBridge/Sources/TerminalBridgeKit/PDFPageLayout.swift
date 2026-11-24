import Foundation

/// One measured piece of a PDF page: a heading, a table row, a chart, a chunk of a reply.
public struct PDFLayoutBlock: Hashable, Sendable {
    public let height: Double
    /// Starts a page of its own (a cover, the summary).
    public let startsPage: Bool
    /// Moves to the next page with the block after it rather than ending a page alone (a heading).
    public let keepsWithNext: Bool
    /// Index of the block repeated at the top of a page this block opens after a break: a table's header row.
    public let header: Int?

    public init(height: Double, startsPage: Bool = false, keepsWithNext: Bool = false, header: Int? = nil) {
        self.height = height
        self.startsPage = startsPage
        self.keepsWithNext = keepsWithNext
        self.header = header
    }
}

/// Which blocks go on which page, from their measured heights. Pure, so the paging is tested without rendering.
public enum PDFPageLayout {
    /// Block indices per page, in order; a repeated table header appears again on the page it opens. A block taller
    /// than `pageHeight` gets a page to itself and is clipped there: callers cut long text with
    /// ``ExportText/chunks(_:maxLines:maxCharacters:)`` first.
    public static func pages(for blocks: [PDFLayoutBlock], pageHeight: Double, spacing: Double) -> [[Int]] {
        var pages: [[Int]] = []
        var current: [Int] = []
        var used = 0.0
        for (index, block) in blocks.enumerated() {
            let forced = block.startsPage && !current.isEmpty
            let run = runHeight(from: index, in: blocks, spacing: spacing)
            let needed = run <= pageHeight ? run : block.height
            let overflows = !current.isEmpty && used + spacing + needed > pageHeight
            if forced || overflows {
                pages.append(current)
                current.removeAll()
                used = 0
                if overflows, !forced, let header = block.header, header != index, blocks.indices.contains(header) {
                    current.append(header)
                    used = blocks[header].height
                }
            }
            used += (current.isEmpty ? 0 : spacing) + block.height
            current.append(index)
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }

    /// The block plus the ones it keeps with: a heading needs room for what follows it. A run taller than a page
    /// only asks for the block itself.
    static func runHeight(from index: Int, in blocks: [PDFLayoutBlock], spacing: Double) -> Double {
        var total = blocks[index].height
        var last = index
        while blocks[last].keepsWithNext, last + 1 < blocks.count, !blocks[last + 1].startsPage {
            last += 1
            total += spacing + blocks[last].height
        }
        return total
    }
}
