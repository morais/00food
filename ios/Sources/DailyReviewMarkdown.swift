import Foundation
import SwiftUI

enum DailyReviewMarkdown {
    struct Block: Identifiable {
        let id: Int
        var text: AttributedString
        let headingLevel: Int?
        let listMarker: String?
        let listDepth: Int
        let isQuote: Bool
    }

    static func blocks(_ markdown: String) -> [Block] {
        guard let parsed = try? AttributedString(markdown: markdown) else {
            return [Block(id: 0, text: AttributedString(markdown), headingLevel: nil,
                          listMarker: nil, listDepth: 0, isQuote: false)]
        }
        var blocks: [Block] = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity ?? 0
            var heading: Int?
            var ordinal: Int?
            var ordered = false
            var depth = 0
            var quote = false
            for component in components {
                switch component.kind {
                case .header(let level): heading = level
                case .listItem(let number): ordinal = number
                case .orderedList: ordered = true; depth += 1
                case .unorderedList: depth += 1
                case .blockQuote: quote = true
                default: break
                }
            }
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            // Render text links only; no remote image loading or arbitrary URL schemes.
            if let link = text.link, !["http", "https"].contains(link.scheme?.lowercased() ?? "") { text.link = nil }
            if blocks.last?.id == identity {
                blocks[blocks.count - 1].text.append(text)
            } else {
                blocks.append(Block(id: identity, text: text, headingLevel: heading,
                                    listMarker: depth > 0 ? (ordered ? "\(ordinal ?? 1)." : "•") : nil,
                                    listDepth: depth, isQuote: quote))
            }
        }
        return blocks
    }
}

struct DailyReviewText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(DailyReviewMarkdown.blocks(markdown)) { block in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if let marker = block.listMarker { Text(marker).foregroundStyle(.secondary) }
                    Text(block.text)
                        .font(block.headingLevel == nil ? .subheadline : .subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 12)
                .padding(.leading, block.isQuote ? 10 : 0)
                .accessibilityElement(children: .combine)
            }
        }
        .textSelection(.enabled)
    }
}
