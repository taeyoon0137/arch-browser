// The find bar floats over the page's top-right corner. Typing searches the selected tab, Return and the arrows move through matches, and Escape or its close button closes the bar.
import SwiftUI

/// The find bar over the selected tab's page; `SplitView` shows it while the window model's find bar is open.
struct FindBarView: View {
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @FocusState private var isFocused: Bool
    @State private var minimumFieldWidth: CGFloat = 0

    private var resultLabel: String {
        guard !windowModel.findText.isEmpty, let result = windowModel.findResult else { return "" }
        return result.numberOfMatches == 0 ? localized("Not found") : localized("\(result.activeMatchOrdinal) of \(result.numberOfMatches)")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(localized("Find in page"), text: $windowModel.findText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(minWidth: minimumFieldWidth)
                .background {
                    // Reserve the placeholder's natural width without duplicating the input field.
                    Text(localized("Find in page"))
                        .font(.system(size: 13))
                        .fixedSize()
                        .hidden()
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                        .onGeometryChange(for: CGFloat.self) { ceil($0.size.width) } action: { minimumFieldWidth = $0 }
                }
                .focused($isFocused)
                .reportsFocus(of: .find, isFocused: isFocused)
                .onSubmit {
                    if NSEvent.modifierFlags.contains(.shift) { windowModel.findPrevious() } else { windowModel.findNext() }
                }
                .onExitCommand { windowModel.hideFindBar() }
            Text(resultLabel)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // A narrow pane shortens the field, not the count.
                .fixedSize()
            SidebarIconButton(symbol: "chevron.up", label: localized("Previous Match"), shortcut: windowModel.session.menuShortcut("findPrevious"), action: windowModel.findPrevious)
            SidebarIconButton(symbol: "chevron.down", label: localized("Next Match"), shortcut: windowModel.session.menuShortcut("findNext"), action: windowModel.findNext)
            SidebarIconButton(symbol: "xmark", label: localized("Close Find Bar"), action: windowModel.hideFindBar)
        }
        .padding(.horizontal, 12)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: FindBarRequiredWidthKey.self, value: FindBarWidthMeasurement(content: geometry.size.width))
        })
        // Accept the pane's proposed width even when the unchanged controls need more room.
        .frame(minWidth: 0, maxWidth: 380)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: FindBarRequiredWidthKey.self, value: FindBarWidthMeasurement(offered: geometry.size.width))
        })
        .frame(height: 40)
        // A solid background: a material over the engine's view cannot sample it, which leaves the label and buttons nearly invisible.
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .onAppear { DispatchQueue.main.async { isFocused = true } }
        .onChange(of: windowModel.findBarFocusRequests) { isFocused = true }
    }
}

/// Reports actual overflow of the live bar, without creating a second search field.
struct FindBarWidthMeasurement: Equatable {
    var content: CGFloat = 0
    var offered: CGFloat = 0

    var requiredWidth: CGFloat { content > offered + 0.5 ? ceil(content) : 0 }
}

struct FindBarRequiredWidthKey: PreferenceKey {
    static let defaultValue = FindBarWidthMeasurement()

    static func reduce(value: inout FindBarWidthMeasurement, nextValue: () -> FindBarWidthMeasurement) {
        let next = nextValue()
        value.content = max(value.content, next.content)
        value.offered = max(value.offered, next.offered)
    }
}
