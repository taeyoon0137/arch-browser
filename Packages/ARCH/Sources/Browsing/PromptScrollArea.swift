// A scroll view as tall as its content up to a limit, so that a prompt's short text takes only its own height and a long one scrolls. A plain scroll view would take all the height it is offered. Its ideal height is that height, which a card measures itself by (`PromptHeightLimit`), and its content's height stays inside it, so an area inside another one, as the page's words in a card's middle, does not stretch the outer one.
import SwiftUI

/// A vertical scroll view as tall as its content up to `maxHeight`; `PromptCard` puts long text in it.
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
        .frame(idealHeight: height, maxHeight: height)
        .onPreferenceChange(PromptContentHeightKey.self) { height in
            // Measuring is no change the user sees, so it takes no animation.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { contentHeight = height }
        }
        .transformPreference(PromptContentHeightKey.self) { $0 = 0 }
    }

    private var height: CGFloat {
        min(contentHeight, maxHeight ?? .infinity)
    }
}

/// Carries the content's measured height up to `PromptScrollArea`, which sizes itself by it.
private struct PromptContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
