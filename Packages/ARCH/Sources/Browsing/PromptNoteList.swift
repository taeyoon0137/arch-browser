// The notes below a prompt card's fields, each a symbol and a sentence that VoiceOver reads as one. An error's sentence is red, or the primary color with Increase Contrast; its symbol says it is an error either way.
import SwiftUI

struct PromptNoteList: View {
    let notes: [PromptNote]
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(notes) { note in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    symbol(of: note)
                    Text(note.text)
                        .foregroundStyle(textStyle(of: note.tone))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11))
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func symbol(of note: PromptNote) -> some View {
        let image = Image(systemName: note.symbol).accessibilityHidden(true)
        switch note.tone {
        case .info: image.foregroundStyle(.secondary)
        case .warning: image.symbolRenderingMode(.multicolor)
        case .error: image.foregroundStyle(.red)
        }
    }

    private func textStyle(of tone: PromptNote.Tone) -> AnyShapeStyle {
        guard tone == .error else { return AnyShapeStyle(.secondary) }
        return contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.red)
    }
}
