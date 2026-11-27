// A dragged tab or favorite keeps one icon and backing as it changes between a row and a tile.
import AppKit
import ARCHEngine
import SwiftUI

struct SidebarTabDragPreview: View, Animatable {
    @ObservedObject var session: BrowserSession
    let tab: Tab?
    /// The source favorite remains through its transfer to a tab; a drag started as a tab has none.
    let favorite: Favorite?
    var size: CGSize
    var tileFraction: CGFloat
    let isLifted: Bool
    var anchor: UnitPoint = .topLeading
    var scale: CGFloat = 1
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var favoriteIcon: NSImage?
    @State private var iconURL: URL?

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(size.width, size.height), tileFraction) }
        set {
            size = CGSize(width: newValue.first.first, height: newValue.first.second)
            tileFraction = newValue.second
        }
    }

    private var fraction: CGFloat { min(1, max(0, tileFraction)) }
    private var isSelected: Bool {
        if let tab, tab.id == windowModel.selectedTabID { return true }
        return favorite.map { $0.id == windowModel.selectedFavoriteID } ?? false
    }
    private var rowFill: Color {
        if isSelected { return SidebarFill.selected.color(in: colorScheme) }
        if let tab, windowModel.isInSplitViewOnScreen(tab) {
            return SidebarFill.selected.color(in: colorScheme).opacity(colorScheme == .dark ? 0.7 : 0.5)
        }
        return .clear
    }
    private var isDimmed: Bool {
        if let favorite {
            return !(tab?.isLoaded == true || session.hasOpenPage(favorite))
        }
        guard let tab else { return true }
        return (!tab.isLoaded && !isSelected) || windowModel.isShownInAnotherWindow(tab)
    }

    var body: some View {
        let fraction = fraction
        let shape = RoundedRectangle(cornerRadius: 12 - 2 * fraction, style: .continuous)
        shape.fill(.regularMaterial)
            .opacity(isLifted ? 1 : 0)
            .overlay(shape.fill(SidebarFill.selected.color(in: colorScheme)).opacity(isLifted ? 1 - fraction : 0))
            .overlay(shape.fill(rowFill).opacity(1 - fraction))
            .overlay(shape.fill(SidebarFill.field.color(in: colorScheme)).opacity(fraction))
            .overlay(shape.fill(SidebarFill.selected.color(in: colorScheme)).opacity(isSelected ? fraction : 0))
            .shadow(color: .black.opacity(isSelected && colorScheme == .light ? 0.08 : 0), radius: 1.5, y: 0.5)
            .overlay {
                if let tab {
                    TabPlaybackWaveform(tab: tab, isEnabled: favorite != nil || isSelected)
                        .clipShape(shape)
                }
            }
            .overlay(alignment: .leading) {
                rowDetails
                    .frame(width: max(0, size.width - 42), height: size.height, alignment: .leading)
                    .clipped()
                    .opacity(1 - fraction)
                    .offset(x: 36)
            }
            .overlay {
                icon
                    .frame(width: 18 - 2 * fraction, height: 18 - 2 * fraction)
                    .opacity(isDimmed ? SidebarDimming.unopened : 1)
                    .position(x: 19 + (size.width / 2 - 19) * fraction, y: size.height / 2)
            }
            .overlay(alignment: .topTrailing) {
                TabPromptIndicator(prompts: session.prompts, tabID: tab?.id ?? favorite.flatMap { session.favoriteTabs[$0.id]?.id })
                    .opacity(fraction)
                    .offset(x: 3, y: -2)
            }
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            // Resizing around the grab point leaves pointer motion independent of the spring.
            .offset(x: -size.width * anchor.x, y: -size.height * anchor.y)
            .onAppear(perform: loadFavoriteIcon)
            .onChange(of: favorite?.url) {
                favoriteIcon = nil
                loadFavoriteIcon()
            }
    }

    @ViewBuilder private var icon: some View {
        if favorite != nil {
            if let favoriteIcon {
                Image(nsImage: favoriteIcon)
                    .resizable()
                    .interpolation(.high)
                    .clipShape(RoundedRectangle(cornerRadius: 3 + fraction, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        } else if let tab {
            TabIconView(tab: tab)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var rowDetails: some View {
        if let tab {
            SidebarTabDragDetails(session: session, tab: tab)
        } else {
            Text(favorite?.title ?? "")
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(isDimmed ? SidebarDimming.unopened : 1)
        }
    }

    private func loadFavoriteIcon() {
        let url = favorite?.url
        iconURL = url
        guard let url else { return }
        FaviconLoader.loadPageIcon(for: url) { image in
            if iconURL == url { favoriteIcon = image }
        }
    }
}

/// The row's title and status keep observing the tab while its icon and backing morph independently.
private struct SidebarTabDragDetails: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: Tab
    @ObservedObject private var commandKey = CommandKeyState.shared
    @EnvironmentObject private var windowModel: BrowserWindowModel

    var body: some View {
        let isShownElsewhere = windowModel.isShownInAnotherWindow(tab)
        let isDimmed = (!tab.isLoaded && tab.id != windowModel.selectedTabID) || isShownElsewhere
        HStack(spacing: 8) {
            if tab.isAudible || tab.isAudioMuted { TabAudioBadge(isMuted: tab.isAudioMuted) }
            Text(tab.shownTitle)
                .font(.system(size: 14))
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(isDimmed ? SidebarDimming.unopened : 1)
            if isShownElsewhere { TabShownElsewhereBadge() }
            TabPromptIndicator(prompts: session.prompts, tabID: tab.id)
            Spacer(minLength: 0)
            if commandKey.showsShortcuts, let number = windowModel.shortcutNumber(for: tab) {
                TabShortcutBadge(number: number)
            } else if tab.isUnread {
                TabUnreadDot()
            }
        }
    }
}
