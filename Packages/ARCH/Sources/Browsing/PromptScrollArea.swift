// A scroll view as tall as its content up to a limit, so that a prompt's short text takes only its own height and a long one scrolls. A plain scroll view would take all the height it is offered.
import SwiftUI

struct PromptScrollArea<Content: View>: View {
    /// The tallest it gets, or nil for whatever the card leaves it.
    var maxHeight: CGFloat?
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PromptContentHeightKey.self, value: proxy.size.height)
                })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: min(contentHeight, maxHeight ?? .infinity))
        .onPreferenceChange(PromptContentHeightKey.self) { height in
            // Measuring is no change the user sees, so it takes no animation.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { contentHeight = height }
        }
    }
}

private struct PromptContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
