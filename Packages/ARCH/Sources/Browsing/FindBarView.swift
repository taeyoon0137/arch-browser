// The find bar floats over the page's top-right corner. Typing searches the selected tab, Return and the arrows move through matches, and Escape closes the bar.
import SwiftUI

struct FindBarView: View {
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @FocusState private var isFocused: Bool

    private var resultLabel: String {
        guard !windowModel.findText.isEmpty, let result = windowModel.findResult else { return "" }
        return result.numberOfMatches == 0 ? "Not found" : "\(result.activeMatchOrdinal) of \(result.numberOfMatches)"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Find in page", text: $windowModel.findText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onSubmit {
                    if NSEvent.modifierFlags.contains(.shift) { windowModel.findPrevious() } else { windowModel.findNext() }
                }
                .onExitCommand { windowModel.hideFindBar() }
            Text(resultLabel)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            SidebarIconButton(symbol: "chevron.up", label: "Previous Match", action: windowModel.findPrevious)
            SidebarIconButton(symbol: "chevron.down", label: "Next Match", action: windowModel.findNext)
            Button("Done", action: windowModel.hideFindBar)
                .font(.system(size: 12))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(width: 380, height: 40)
        // A solid background: a material over the engine's view cannot sample it, which leaves the label and buttons nearly invisible.
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .onAppear { DispatchQueue.main.async { isFocused = true } }
        .onChange(of: windowModel.findBarFocusRequests) { isFocused = true }
    }
}
