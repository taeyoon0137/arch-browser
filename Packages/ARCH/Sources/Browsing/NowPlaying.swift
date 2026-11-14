// Shows a tab's media in the system's Now Playing and answers the media keys, through MediaPlayer on both engines.
import AppKit
import ARCHEngine
import Combine
import MediaPlayer

/// Feeds `MPNowPlayingInfoCenter` from the media session of the focused tab, the active window's selected tab, while it plays sound, and otherwise of the tab that played sound last, and sends `MPRemoteCommandCenter` commands to that session. The page's Media Session metadata names the media; without it, the page's title and site stand in.
@MainActor final class NowPlaying: @preconcurrency EngineMediaSessionDelegate {
    private weak var session: BrowserSession?
    private var cancellables: Set<AnyCancellable> = []
    private var tabObservers: [UUID: AnyCancellable] = [:]
    /// When each tab last started or stopped playing sound. Tabs that never played sound have no entry.
    private var audibleChangedAt: [UUID: Date] = [:]
    /// The tab whose media Now Playing shows.
    private weak var shownTab: Tab?
    /// Set once Now Playing has shown a tab. Until then the app leaves the system's Now Playing and the media keys to other apps.
    private var hasCommandTargets = false
    private var isUpdateScheduled = false
    /// The last artwork address and the image loaded from it, or nil when it failed to load.
    private var artwork: (url: URL, image: NSImage?)?
    private var loadingArtworkURL: URL?

    init(session: BrowserSession) {
        self.session = session
        // A favorite's tab plays media like a space's tab.
        session.$tabs.combineLatest(session.$favoriteTabs) { tabs, favoriteTabs in tabs + favoriteTabs.values }
            .sink { [weak self] tabs in self?.observe(tabs) }
            .store(in: &cancellables)
        session.$focusedTabID.sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &cancellables)
    }

    private func observe(_ tabs: [Tab]) {
        let ids = Set(tabs.map(\.id))
        tabObservers = tabObservers.filter { ids.contains($0.key) }
        audibleChangedAt = audibleChangedAt.filter { ids.contains($0.key) }
        for tab in tabs where tabObservers[tab.id] == nil {
            // A tab that switches engines gets another web contents with its own media session.
            let media = tab.$webContents.sink { [weak self] webContents in webContents.mediaSession.delegate = self }
            let audible = tab.$isAudible.removeDuplicates().sink { [weak self, weak tab] isAudible in
                guard let self, let tab, isAudible || self.audibleChangedAt[tab.id] != nil else { return }
                self.audibleChangedAt[tab.id] = Date()
                self.scheduleUpdate()
            }
            // The page's title and site stand in for missing metadata.
            let page = Publishers.Merge(tab.$title.map { _ in }, tab.$url.map { _ in }).sink { [weak self, weak tab] in
                if let self, let tab, tab === self.shownTab { self.scheduleUpdate() }
            }
            tabObservers[tab.id] = AnyCancellable {
                media.cancel()
                audible.cancel()
                page.cancel()
            }
        }
        scheduleUpdate()
    }

    func mediaSessionDidChange(_ session: any EngineMediaSession) { scheduleUpdate() }

    /// Combines the changes of one run loop turn into one update. Published values also arrive before they are stored.
    private func scheduleUpdate() {
        guard !isUpdateScheduled else { return }
        isUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isUpdateScheduled = false
            self?.update()
        }
    }

    /// The focused tab while it plays sound; otherwise the tab that plays sound and started last, or, while none plays, the one that stopped last.
    private func tabToShow() -> Tab? {
        guard let session else { return nil }
        let candidates = session.allTabs.filter { audibleChangedAt[$0.id] != nil && $0.webContents.mediaSession.playbackState != .none }
        if let focused = session.focusedTab, focused.isAudible, candidates.contains(where: { $0 === focused }) { return focused }
        return candidates.max { ($0.isAudible ? 1 : 0, audibleChangedAt[$0.id] ?? .distantPast) < ($1.isAudible ? 1 : 0, audibleChangedAt[$1.id] ?? .distantPast) }
    }

    private func update() {
        let tab = tabToShow()
        shownTab = tab
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        guard let tab else {
            guard hasCommandTargets else { return }
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            for command in [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand, commands.nextTrackCommand, commands.previousTrackCommand] {
                command.isEnabled = false
            }
            return
        }
        addCommandTargets()
        let media = tab.webContents.mediaSession
        let metadata = media.metadata
        let title = metadata.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? tab.pageTitle
        // The site as the address pill names it; a page without a host, such as a local file, leaves the line out.
        let artist = metadata.map(\.artist).flatMap { $0.isEmpty ? nil : $0 } ?? tab.url.flatMap { $0.host == nil ? nil : AddressPillView.siteName(of: $0) }
        var info: [String: Any] = [MPMediaItemPropertyTitle: title]
        if let artist, !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
        if let album = metadata?.album, !album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = album }
        if let position = media.position {
            if position.duration.isInfinite {
                info[MPNowPlayingInfoPropertyIsLiveStream] = true
            } else if position.duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = position.duration
            }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position.position
            info[MPNowPlayingInfoPropertyPlaybackRate] = media.playbackState == .playing ? position.playbackRate : 0
        }
        if let image = artworkImage(for: metadata?.artwork) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        center.nowPlayingInfo = info
        center.playbackState = media.playbackState == .playing ? .playing : .paused
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = media.canGoToNextTrack
        commands.previousTrackCommand.isEnabled = media.canGoToPreviousTrack
    }

    private func addCommandTargets() {
        guard !hasCommandTargets else { return }
        hasCommandTargets = true
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in self?.run { $0.play() } ?? .noActionableNowPlayingItem }
        commands.pauseCommand.addTarget { [weak self] _ in self?.run { $0.pause() } ?? .noActionableNowPlayingItem }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.run { $0.playbackState == .playing ? $0.pause() : $0.play() } ?? .noActionableNowPlayingItem
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in self?.run { $0.nextTrack() } ?? .noActionableNowPlayingItem }
        commands.previousTrackCommand.addTarget { [weak self] _ in self?.run { $0.previousTrack() } ?? .noActionableNowPlayingItem }
    }

    /// Runs a command on the shown tab's media session. The header does not say on which thread commands arrive, so one from another thread moves to the main thread.
    nonisolated private func run(_ command: @escaping @MainActor (any EngineMediaSession) -> Void) -> MPRemoteCommandHandlerStatus {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in _ = self?.run(command) }
            return .success
        }
        return MainActor.assumeIsolated {
            guard let media = shownTab?.webContents.mediaSession else { return .noActionableNowPlayingItem }
            command(media)
            return .success
        }
    }

    /// The most bytes an artwork image may have. Larger artwork shows none.
    static let maximumArtworkSize = 5 << 20

    /// The image loaded from `url`. The first request starts loading it, and Now Playing updates once it arrives. The page names the address, so artwork loads as site icons do (`FaviconLoader.download`): outside every Persona's store, without cookies or stored credentials, within 30 seconds, and up to `maximumArtworkSize`.
    private func artworkImage(for url: URL?) -> NSImage? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "data"].contains(scheme) else { return nil }
        if let artwork, artwork.url == url { return artwork.image }
        guard loadingArtworkURL != url else { return nil }
        loadingArtworkURL = url
        Task { @MainActor [weak self] in
            let image = await FaviconLoader.download(url, limit: Self.maximumArtworkSize).flatMap(NSImage.init(data:))
            guard let self, self.loadingArtworkURL == url else { return }
            self.loadingArtworkURL = nil
            self.artwork = (url, image)
            self.scheduleUpdate()
        }
        return nil
    }
}
