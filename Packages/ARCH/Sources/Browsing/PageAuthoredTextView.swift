// A page's or server's own words in a prompt card: in a box of their own below Arch's words, as written, selectable, and scrolling past 180 points. VoiceOver reads them as a message from the site.
import SwiftUI

struct PageAuthoredTextView: View {
    let text: PageAuthoredText
    /// The site that wrote the text, which VoiceOver names.
    let author: String
    var maxHeight: CGFloat = 180
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption = text.caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            PromptScrollArea(maxHeight: maxHeight) {
                Text(verbatim: text.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(SidebarFill.field.color(in: colorScheme)))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.35)).allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(text.caption.map { "\($0), message from \(author)" } ?? "Message from \(author)")
            .accessibilityValue(Text(verbatim: text.text))
        }
    }
}
