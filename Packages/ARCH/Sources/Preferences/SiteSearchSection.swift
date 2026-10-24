// The Site Search section of Settings: the keyword shortcuts that search a site from the command palette. A sheet adds, edits, and removes each one.
import Browsing
import SwiftUI

/// Lists the shortcuts by name, address, and keyword. Many shortcuts scroll within the section instead of making the window taller.
struct SiteSearchSection: View {
    @ObservedObject private var store = SiteSearchStore.shared
    /// The shortcut the sheet edits: one from the list, or a new one the list does not have yet.
    @State private var editing: SiteSearchShortcut?

    var body: some View {
        Form {
            Section {
                if store.shortcuts.isEmpty {
                    Text("No shortcuts")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.shortcuts) { shortcut in
                    LabeledContent {
                        HStack(spacing: 12) {
                            Text(shortcut.keyword)
                                .font(.body.monospaced())
                            Button("Edit\u{2026}") { editing = shortcut }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shortcut.name)
                            Text(shortcut.template)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Type a keyword and a space in the command palette to search its site.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add\u{2026}") { editing = SiteSearchShortcut(keyword: "", name: "", template: "") }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: sectionWidth)
        .frame(maxHeight: 520)
        .sheet(item: $editing) { shortcut in
            SiteSearchEditor(shortcut: shortcut, isNew: !store.shortcuts.contains { $0.id == shortcut.id })
        }
    }
}

/// Edits one shortcut. Saving needs a name, a one-word keyword that no other shortcut uses, and an address with `%s` where the search text goes.
private struct SiteSearchEditor: View {
    @ObservedObject private var store = SiteSearchStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var shortcut: SiteSearchShortcut
    /// Kept from when the sheet opened, so its buttons stay the same while it closes after Add.
    @State private var isNew: Bool

    init(shortcut: SiteSearchShortcut, isNew: Bool) {
        _shortcut = State(initialValue: shortcut)
        _isNew = State(initialValue: isNew)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $shortcut.name, prompt: Text("Example"))
                    TextField("Keyword", text: $shortcut.keyword, prompt: Text("ex"))
                    // Verbatim text keeps `%s` from being read as a format specifier.
                    TextField("Address", text: $shortcut.template, prompt: Text(verbatim: "https://example.com/search?q=%s"))
                } footer: {
                    Text(verbatim: store.isKeywordInUse(shortcut.keyword, except: shortcut.id)
                        ? "Another shortcut uses this keyword."
                        : "Put %s in the address where the search text goes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        store.remove(shortcut)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    store.save(shortcut)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!store.canSave(shortcut))
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: sectionWidth)
    }
}
