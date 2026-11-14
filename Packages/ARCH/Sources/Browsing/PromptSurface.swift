// The surface of a prompt card: the window background, the separator edge of the find bar and the question popover, which Increase Contrast strengthens, an inner highlight in the dark appearance, and a soft shadow with a tight contact shadow. It is opaque, like the find bar's, because a material over the engine's view cannot sample it; a screen check that finds a material that does would change only this file.
import AppKit
import SwiftUI

struct PromptSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let isHighContrast = contrast == .increased
        content
            .clipShape(shape)
            .background {
                shape.fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 0.5, y: 0.5)
                    .shadow(color: .black.opacity(isDark ? 0.5 : 0.18), radius: 16, y: 6)
            }
            .overlay {
                ZStack {
                    if isDark, !isHighContrast {
                        shape.inset(by: 1).strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                    }
                    shape.strokeBorder(isHighContrast ? Color.primary.opacity(0.5) : Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .allowsHitTesting(false)
            }
    }
}
