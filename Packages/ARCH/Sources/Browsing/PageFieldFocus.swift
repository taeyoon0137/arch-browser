// The text fields that float over the selected tab's page, the find bar's and the question popover's, report their keyboard focus to the window, so that a prompt card over that page counts their focus as the page's (`PromptPresentation.isInPage`). Other fields over the pane, as the palette's or the floating sidebar's, report nothing.
import SwiftUI

enum PageField: Hashable {
    case find, question
}

extension View {
    /// Reports to the window whether `field` has the keyboard focus, and that it has not once it goes.
    func reportsFocus(of field: PageField, isFocused: Bool) -> some View {
        modifier(PageFieldFocusReport(field: field, isFocused: isFocused))
    }
}

private struct PageFieldFocusReport: ViewModifier {
    @EnvironmentObject private var windowModel: BrowserWindowModel
    let field: PageField
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: isFocused, initial: true) { _, isFocused in windowModel.pageField(field, isFocused: isFocused) }
            .onDisappear { windowModel.pageField(field, isFocused: false) }
    }
}
