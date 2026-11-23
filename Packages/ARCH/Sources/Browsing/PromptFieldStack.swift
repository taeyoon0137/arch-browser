// A prompt card's text fields: standard rounded fields at the large size, a secure field for a password, which turns on secure input while the user types, and the content types that let password managers recognize a login. Return in a field presses the card's default button.
import AppKit
import SwiftUI

/// What has the keyboard focus inside a card: the card itself, one of its fields, or, with full keyboard access, one of its buttons.
enum PromptFocus: Hashable {
    case card
    case field(String)
    case button(String)
}

/// The text fields of a `PromptCard`, which write into `values` by field ID and submit on Return.
struct PromptFieldStack: View {
    let fields: [PromptField]
    @Binding var values: [String: String]
    var focus: FocusState<PromptFocus?>.Binding
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(fields) { field in
                input(for: field)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .textContentType(contentType(of: field))
                    .focused(focus, equals: .field(field.id))
                    .onSubmit(onSubmit)
                    .accessibilityLabel(field.label)
            }
        }
    }

    @ViewBuilder private func input(for field: PromptField) -> some View {
        let text = Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = $0 })
        if field.kind == .password {
            SecureField(field.label, text: text)
        } else {
            TextField(field.label, text: text)
        }
    }

    private func contentType(of field: PromptField) -> NSTextContentType? {
        switch field.kind {
        case .userName: .username
        case .password: .password
        case .text: nil
        }
    }
}
