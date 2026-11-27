// Background media stays above the space strip and fans upward while its controls are in use.
import AppKit
import ARCHEngine
import ARCHPrivateAPI
import SwiftUI

struct SidebarMediaStackView: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var nowPlaying: NowPlaying
    let maximumHeight: CGFloat
    @EnvironmentObject private var windowModel: BrowserWindowModel
    @Environment(\.sidebarIsFloating) private var isFloating
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @FocusState private var focusedControl: SidebarMediaControl?

    private var isActiveHost: Bool {
        !windowModel.isPrivate && !windowModel.isLibraryVisible && !windowModel.isPageFullscreen
            && (isFloating ? !windowModel.isSidebarVisible : windowModel.isSidebarVisible)
    }

    /// Resolve the current tab each time: a snapshot never owns a page or permits an action after it changes scope.
    private func tab(for id: UUID) -> Tab? {
        guard !windowModel.isPrivate,
              let tab = session.allTabs.first(where: { $0.id == id }),
              tab.personaID == windowModel.personaID, !tab.isPrivate, !tab.isInSmallWindow,
              windowModel.selectedTabID != tab.id, !windowModel.shows(tab), tab.isLoaded,
              tab.webContents.mediaSession.playbackState != .none else { return nil }
        return tab
    }

    private var items: [NowPlaying.Item] {
        nowPlaying.items.filter { $0.personaID == windowModel.personaID && tab(for: $0.id) != nil }
    }

    private var isExpanded: Bool { isHovered || focusedControl != nil }
    private var animation: Animation? { reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.9) }

    var body: some View {
        let visibleItems = items
        let expanded = isExpanded
        let height = visibleItems.isEmpty ? 0 : expanded ? CGFloat(visibleItems.count * 66 + (visibleItems.count - 1) * 5) : CGFloat(33 + (visibleItems.count - 1) * 7)
        Group {
            if !visibleItems.isEmpty {
                GeometryReader { geometry in
                    ScrollView(.vertical) {
                        ZStack(alignment: .bottom) {
                            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                                if let tab = tab(for: item.id) {
                                    let rank = visibleItems.count - index - 1
                                    SidebarMediaCard(item: item, tab: tab, expanded: expanded, focusedControl: $focusedControl) { control in
                                        perform(control)
                                    }
                                    .frame(width: max(0, geometry.size.width - (expanded ? 0 : CGFloat(min(rank * 10, 90)))), height: expanded ? 66 : 33)
                                    .offset(y: -CGFloat(rank * (expanded ? 71 : 7)))
                                    .opacity(expanded ? 1 : max(1 - Double(rank) * 0.2, 0.4))
                                    .zIndex(Double(index))
                                    .disabled(!isActiveHost || (!expanded && rank != 0))
                                    .allowsHitTesting(isActiveHost && (expanded || rank == 0))
                                    .accessibilityHidden(!isActiveHost || (!expanded && rank != 0))
                                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
                                }
                            }
                        }
                        .frame(width: geometry.size.width, height: height, alignment: .bottom)
                    }
                    .defaultScrollAnchor(.bottom)
                    .scrollIndicators(.hidden)
                    .scrollDisabled(!expanded || height <= maximumHeight)
                    .scrollClipDisabled(height <= maximumHeight)
                    .contentShape(Rectangle())
                    .onHover { isHovered = isActiveHost && $0 }
                }
                .frame(height: min(height, maximumHeight))
            }
        }
        .animation(animation, value: expanded)
        .animation(animation, value: visibleItems.map(\.id))
        .onChange(of: visibleItems.map(\.id)) { _, ids in
            if let focusedControl, !ids.contains(focusedControl.tabID) { self.focusedControl = nil }
            if ids.isEmpty { isHovered = false }
        }
        .onChange(of: isActiveHost) { _, active in
            if !active { isHovered = false; focusedControl = nil }
        }
        .onDisappear { isHovered = false; focusedControl = nil }
    }

    private func perform(_ control: SidebarMediaControl) {
        guard isActiveHost, nowPlaying.items.contains(where: { $0.id == control.tabID }),
              let tab = tab(for: control.tabID) else { return }
        let media = tab.webContents.mediaSession
        switch control {
        case .show:
            windowModel.selectTab(tab.id)
        case .previous:
            if media.canGoToPreviousTrack { media.previousTrack() }
        case .playPause:
            if media.playbackState == .playing { media.pause() } else { media.play() }
        case .next:
            if media.canGoToNextTrack { media.nextTrack() }
        case .mute:
            if tab.canSetAudioMuted { tab.setAudioMuted(!tab.isAudioMuted) }
        case .close:
            nowPlaying.dismiss(tab)
        }
    }
}

private enum SidebarMediaControl: Hashable {
    case show(UUID), previous(UUID), playPause(UUID), next(UUID), mute(UUID), close(UUID)

    var tabID: UUID {
        switch self {
        case .show(let id), .previous(let id), .playPause(let id), .next(let id), .mute(let id), .close(let id): id
        }
    }
}

private struct SidebarMediaCard: View {
    let item: NowPlaying.Item
    @ObservedObject var tab: Tab
    @ObservedObject private var privateAPIFlags = PrivateAPIFlags.shared
    let expanded: Bool
    var focusedControl: FocusState<SidebarMediaControl?>.Binding
    let action: (SidebarMediaControl) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.spaceTheme) private var theme
    @State private var artwork: NSImage?

    var body: some View {
        ZStack {
            // Independent controls sit above this button, so clicking the row does not wrap or duplicate their actions.
            Button { action(.show(item.id)) } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(interactions: .activate)
            .focused(focusedControl, equals: .show(item.id))
            .help(localized("Back to Tab"))
            .accessibilityLabel(localized("Back to Tab") + ": " + item.title)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer().frame(width: 4)
                    Text(item.title)
                        .font(.system(size: 13))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.8)
                            : Color(nsColor: NSColor(displayP3Red: 14.0 / 255, green: 15.0 / 255, blue: 16.0 / 255, alpha: 0.9)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help([item.title, item.artist].compactMap { $0 }.joined(separator: " — "))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    control("xmark", label: localized("Close Player"), command: .close(item.id))
                        .opacity(expanded ? 1 : 0)
                        .disabled(!expanded)
                        .allowsHitTesting(expanded)
                        .accessibilityHidden(!expanded)
                }
                .padding(.horizontal, 10)
                .frame(height: 33)
                HStack(spacing: 0) {
                    Button { action(.show(item.id)) } label: {
                        Group {
                            if let image = artwork {
                                Image(nsImage: image).resizable().scaledToFill()
                            } else {
                                TabIconView(tab: tab)
                            }
                        }
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SidebarMediaButtonStyle())
                    .focusable(false)
                    .help(localized("Back to Tab"))
                    .accessibilityHidden(true)
                    Spacer(minLength: 8)
                    control("backward.end.fill", label: localized("Previous Track"), command: .previous(item.id), enabled: item.canGoToPreviousTrack)
                    Spacer(minLength: 8)
                    control(item.isPlaying ? "pause.fill" : "play.fill", label: item.isPlaying ? localized("Pause") : localized("Play"), command: .playPause(item.id))
                    Spacer(minLength: 8)
                    control("forward.end.fill", label: localized("Next Track"), command: .next(item.id), enabled: item.canGoToNextTrack)
                    Spacer(minLength: 8)
                    control(tab.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            label: tab.isAudioMuted ? localized("Unmute Tab") : localized("Mute Tab"),
                            command: .mute(item.id), enabled: tab.canSetAudioMuted)
                }
                .padding(.horizontal, 10)
                .frame(height: 33)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: expanded ? 66 : 33, alignment: .bottom)
        }
        .frame(height: expanded ? 66 : 33)
        .background {
            (colorScheme == .dark ? Color.black : Color.white)
                .overlay(theme.tint.opacity(colorScheme == .dark ? 0.15 : 0.02))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.1 : 0), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.2 : 0.08), radius: 4)
        .task(id: item.artworkURL) {
            artwork = nil
            guard let url = item.artworkURL, let scheme = url.scheme?.lowercased(),
                  ["http", "https", "data"].contains(scheme) else { return }
            let data = await FaviconLoader.download(url, limit: NowPlaying.maximumArtworkSize)
            guard !Task.isCancelled else { return }
            artwork = data.flatMap(NSImage.init(data:))
        }
    }

    private func control(_ symbol: String, label: String, command: SidebarMediaControl, enabled: Bool = true) -> some View {
        Button { action(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.66) : Color.black.opacity(0.5))
                .frame(width: 16, height: 16)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarMediaButtonStyle())
        .focusable(interactions: .activate)
        .focused(focusedControl, equals: command)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.33)
        .overlay {
            // An unavailable control must not pass its click to the card's return-to-tab button.
            if !enabled {
                Color.clear.contentShape(Rectangle()).onTapGesture { }.accessibilityHidden(true)
            }
        }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct SidebarMediaButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        private var fill: Color {
            guard isEnabled else { return .clear }
            let isDark = colorScheme == .dark
            let opacity = configuration.isPressed ? (isDark ? 0.103 : 0.09) : isHovered ? (isDark ? 0.077 : 0.071) : 0
            return (isDark ? Color.white : Color.black).opacity(opacity)
        }

        var body: some View {
            configuration.label
                .background(fill, in: RoundedRectangle(cornerRadius: 5))
                .onHover { isHovered = $0 }
        }
    }
}
