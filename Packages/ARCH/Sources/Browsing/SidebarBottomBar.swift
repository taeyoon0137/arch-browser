// The sidebar's bottom bar: the library button, the strip of space symbols with the new space button, which scrolls and shrinks toward its ends when the symbols do not fit, a dot on the symbol of another space whose agent session waits for the user, and the agents indicator while an agent acts.
import AppKit
import SwiftUI

/// The library button at the leading end, and one symbol per space in the middle with the new space button floating after them. With several Personas, a divider separates each Persona's group of symbols. Dragging a symbol moves its space among the others of its Persona; a tab or folder dragged over another space's symbol, of any Persona, lights it up (`SidebarDragState.spaceDestination(forTab:at:session:)`).
struct SidebarBottomBar: View {
    @ObservedObject var session: BrowserSession
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    @Environment(\.sidebarWidth) private var width
    @Environment(\.sidebarIsFloating) private var isFloating
    @Environment(\.spaceTheme) private var theme
    @Environment(\.libraryReveal) private var libraryReveal
    /// The space whose symbol is under the pointer, which brightens as the new space button does.
    @State private var hoveredSpaceID: UUID?

    /// The maximum centered width of the symbols and new space button. Each side reserves room for the 30-point library button and its gap to avoid overlap.
    private var groupWidth: CGFloat { width - 2 * SidebarView.inset - 2 * (30 + 4) }

    /// The bar's height, which the library's button row and the line beside the library repeat.
    static let height: CGFloat = 28

    /// Width shared by each symbol and the new space button, keeping the row visually grouped.
    fileprivate static let itemWidth: CGFloat = 18
    private static let stripSpace = "SpaceStrip"

    /// Three items show at full size: the current space and its neighbors, or the three at the end nearest it. The others shrink with their distance from those three.
    private func scale(at index: Int) -> CGFloat {
        let count = session.spaces.count + 1
        let current = session.spaces.firstIndex { $0.id == windowModel.currentSpaceID } ?? 0
        let first = max(0, min(current - 1, count - 3))
        let distance = index < first ? first - index : max(0, index - (first + 2))
        return max(0.3, pow(0.7, CGFloat(distance)))
    }

    /// The symbols followed by the new space button, with a divider before each Persona's group but the first. When scrolling, items also shrink toward the strip's ends so none appears cut off; dividers keep their size.
    private func strip(shrinksAtEdges: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(session.spaces.enumerated()), id: \.element.id) { index, space in
                if index > 0, session.spaces[index - 1].resolvedPersonaID != space.resolvedPersonaID {
                    PersonaDivider()
                }
                let isCurrent = space.id == windowModel.currentSpaceID
                let isTabTarget = sidebarDrag.targetSpaceID == space.id
                // The bar lists every Persona's spaces, so with several Personas the label names the space's Persona (Persona rule 7).
                let label = session.displayedPlace(ofPersona: space.resolvedPersonaID, space: space) ?? space.name
                // The release that ends a drag of the symbol does not also switch spaces.
                Button(action: { if sidebarDrag.item == nil { windowModel.switchToSpace(space.id) } }) {
                    Image(systemName: space.symbol)
                        .font(.system(size: isCurrent ? 12 : 9))
                        .foregroundStyle(isCurrent || isTabTarget ? theme.symbolColor(for: space.tint) : (hoveredSpaceID == space.id && sidebarDrag.item == nil ? Color.primary : Color.secondary))
                        .scaleEffect(scale(at: index) * (isTabTarget ? 1.4 : 1))
                        .frame(width: Self.itemWidth, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(AgentWaitingDot(agents: session.agents, spaceID: space.id, isCurrent: isCurrent, scale: scale(at: index)))
                .onHover { if $0 { hoveredSpaceID = space.id } else if hoveredSpaceID == space.id { hoveredSpaceID = nil } }
                .modifier(EdgeShrink(isActive: shrinksAtEdges, stripWidth: groupWidth, coordinateSpace: Self.stripSpace))
                .modifier(SidebarItemDrag(item: .space(space.id), cornerRadius: 6) { reorder(space, at: $0) })
                .contextMenu { SpaceMenuItems(session: session, space: space) }
                .help(label)
                .accessibilityLabel(label)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .id(space.id)
            }
            NewSpaceButton(scale: scale(at: session.spaces.count), shortcut: session.menuShortcut("newSpace"), action: windowModel.addSpace)
                .modifier(EdgeShrink(isActive: shrinksAtEdges, stripWidth: groupWidth, coordinateSpace: Self.stripSpace))
        }
        .animation(SidebarView.pageSpring, value: windowModel.currentSpaceID)
        .animation(.easeInOut(duration: 0.15), value: session.spaces.map(\.id))
        // Let the first and last items scroll clear of the shrinking ends.
        .padding(.horizontal, shrinksAtEdges ? EdgeShrink.distance : 0)
    }

    /// The symbol under the pointer makes room for the dragged space, with a light haptic at each new position, while it belongs to the same Persona. Only the strip animates the move; the space pages move at once, so the current page stays in view.
    private func reorder(_ space: Space, at location: CGPoint) {
        guard let id = sidebarDrag.space(at: location), id != space.id, let target = session.spaces.first(where: { $0.id == id }),
              target.resolvedPersonaID == space.resolvedPersonaID else { return }
        session.moveSpace(space.id, to: target)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    var body: some View {
        ZStack {
            HStack {
                // The open library shows its own button in this place, so the one in the sidebar's visible edge fades out as the library comes in.
                LibraryButton(session: session)
                    .opacity(1 - libraryReveal)
                Spacer(minLength: 0)
                AgentsIndicator(session: session)
            }
            // Center the symbols and new space button as one group, ignoring the library button. If they do not fit, scroll them together without covering the library button or widening the sidebar.
            ViewThatFits(in: .horizontal) {
                strip(shrinksAtEdges: false)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) { strip(shrinksAtEdges: true) }
                        .coordinateSpace(name: Self.stripSpace)
                        .onAppear { proxy.scrollTo(windowModel.currentSpaceID, anchor: .center) }
                        .onChange(of: windowModel.currentSpaceID) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            .frame(maxWidth: groupWidth)
            // Dragged spaces and tabs find a symbol only in the strip's visible part.
            .background(GeometryReader { proxy in
                let frame = proxy.frame(in: .named(BrowserWindowView.coordinateSpace))
                Color.clear
                    .onAppear { sidebarDrag.spaceStripFrame = frame }
                    .onChange(of: frame) { sidebarDrag.spaceStripFrame = $1 }
            })
            .onPreferenceChange(SidebarItemFramesKey.self) { sidebarDrag.spaceSymbolFrames = $0 }
            // An optical correction beside the page: the group looks centered 2 points right of its true center. The floating sidebar uses the true center.
            .offset(x: isFloating ? 0 : 2)
        }
        .frame(height: Self.height)
    }
}

/// Shrinks a scrolling item starting three items from either end of the strip, reaching zero at the end.
private struct EdgeShrink: ViewModifier {
    static let distance = 3 * (SidebarBottomBar.itemWidth + 2)

    let isActive: Bool
    let stripWidth: CGFloat
    let coordinateSpace: String

    @ViewBuilder func body(content: Content) -> some View {
        if isActive {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .named(coordinateSpace))
                let nearest = min(frame.midX, stripWidth - frame.midX)
                content.scaleEffect(max(0, min(1, nearest / Self.distance)))
            }
            .frame(width: SidebarBottomBar.itemWidth, height: 26)
        } else {
            content
        }
    }
}

/// Separates two Personas' groups of space symbols: a 1-point line with 6 points of extra space around it.
private struct PersonaDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 1, height: 12)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }
}

/// A small plus in the symbols' gray, brightening under the pointer as they do, makes the new space button look like part of the symbols row rather than a toolbar button.
private struct NewSpaceButton: View {
    let scale: CGFloat
    /// Named in the tooltip, as `SidebarIconButton` names its shortcut.
    let shortcut: String?
    let action: () -> Void
    @EnvironmentObject private var sidebarDrag: SidebarDragState
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                // Like the symbols, the plus ignores the pointer while an item is dragged.
                .foregroundStyle(isHovering && sidebarDrag.item == nil ? Color.primary : Color.secondary)
                .scaleEffect(scale)
                .frame(width: SidebarBottomBar.itemWidth, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(shortcut.map { localized("New Space (\($0))") } ?? localized("New Space"))
        .accessibilityLabel(localized("New Space"))
    }
}
