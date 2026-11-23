// The Site Search section of Settings: the keyword shortcuts that search a site from the command palette. A sheet adds, edits, and removes each one.
import Browsing
import SwiftUI

/// Lists the shortcuts by name, address, and keyword. Many shortcuts scroll within the section instead of making the window taller.
struct SiteSearchSection: View {
    /// The session's shortcuts.
    @ObservedObject var store: SiteSearchStore
    /// The shortcut the sheet edits: one from the list, or a new one the list does not have yet.
    @State private var editing: SiteSearchShortcut?

    var body: some View {
        Form {
            Section {
                if store.shortcuts.isEmpty {
                    Text("No shortcuts", bundle: .module)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.shortcuts) { shortcut in
                    LabeledContent {
                        HStack(spacing: 12) {
                            Text(shortcut.keyword)
                                .font(.body.monospaced())
                            Button(localized("Edit\u{2026}")) { editing = shortcut }
                        }
                    } label: {
                        Text(shortcut.name)
                        Text(shortcut.template)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                HStack {
                    Spacer()
                    Button(localized("Add Shortcut\u{2026}")) { editing = SiteSearchShortcut(keyword: "", name: "", template: "") }
                }
            } footer: {
                formFootnote("Type a keyword and a space in the command palette to search its site.")
            }
        }
        .formStyle(.grouped)
        .frame(width: sectionWidth)
        .frame(maxHeight: 520)
        .sheet(item: $editing) { shortcut in
            SiteSearchEditor(store: store, shortcut: shortcut, isNew: !store.shortcuts.contains { $0.id == shortcut.id })
        }
    }
}

/// Edits one shortcut. Saving needs a name, a one-word keyword that no other shortcut uses, and an address with `%s` where the search text goes.
private struct SiteSearchEditor: View {
    @ObservedObject private var store: SiteSearchStore
    @Environment(\.dismiss) private var dismiss
    @State private var shortcut: SiteSearchShortcut
    /// Kept from when the sheet opened, so its buttons stay the same while it closes after Add.
    @State private var isNew: Bool

    init(store: SiteSearchStore, shortcut: SiteSearchShortcut, isNew: Bool) {
        _store = ObservedObject(wrappedValue: store)
        _shortcut = State(initialValue: shortcut)
        _isNew = State(initialValue: isNew)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(isNew ? "Add Site Search Shortcut" : "Edit Site Search Shortcut")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField(localized("Name"), text: $shortcut.name, prompt: Text("Example", bundle: .module))
                    TextField(localized("Keyword"), text: $shortcut.keyword, prompt: Text("ex", bundle: .module))
                    if store.isKeywordInUse(shortcut.keyword, except: shortcut.id) {
                        Text("Another shortcut uses this keyword.", bundle: .module).font(.callout).foregroundStyle(.red)
                    }
                    // Verbatim text keeps `%s` from being read as a format specifier.
                    TextField(localized("Address"), text: $shortcut.template, prompt: Text(verbatim: "https://example.com/search?q=%s"))
                } footer: {
                    // The footnote's text is verbatim, so `%s` stays as typed.
                    formFootnote("Put %s in the address where the search text goes.")
                }
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button(localized("Remove Shortcut"), role: .destructive) {
                        store.remove(shortcut)
                        dismiss()
                    }
                }
                Spacer()
                Button(localized("Cancel"), role: .cancel) { dismiss() }
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
        .frame(width: 480)
    }
}
