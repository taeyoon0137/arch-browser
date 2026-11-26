// The clicked media's state and actions, shared by the engines and their page menus.
import AppKit

public struct EngineContextMenuMedia: Sendable {
    public enum Kind: Sendable { case video, audio }
    public var kind: Kind
    public var isPaused: Bool
    public var isLooping: Bool
    public var showsControls: Bool
    public var isInPictureInPicture: Bool
    public var canLoop: Bool
    public var canToggleControls: Bool
    public var canPictureInPicture: Bool
    public var canSave: Bool
    public var hasError: Bool

    public init(kind: Kind, isPaused: Bool = false, isLooping: Bool = false, showsControls: Bool = false,
                isInPictureInPicture: Bool = false, canLoop: Bool = true, canToggleControls: Bool = true,
                canPictureInPicture: Bool = false, canSave: Bool = false, hasError: Bool = false) {
        self.kind = kind
        self.isPaused = isPaused
        self.isLooping = isLooping
        self.showsControls = showsControls
        self.isInPictureInPicture = isInPictureInPicture
        self.canLoop = canLoop
        self.canToggleControls = canToggleControls
        self.canPictureInPicture = canPictureInPicture
        self.canSave = canSave
        self.hasError = hasError
    }

    /// Both adapters describe native hit-test state with these keys; the type does not depend on a URL.
    public init?(report: Any?) {
        guard let report = report as? [String: Any], let kind = report["kind"] as? String,
              kind == "video" || kind == "audio" else { return nil }
        self.init(kind: kind == "video" ? .video : .audio,
                  isPaused: report["paused"] as? Bool == true, isLooping: report["loop"] as? Bool == true,
                  showsControls: report["controls"] as? Bool == true, isInPictureInPicture: report["pip"] as? Bool == true,
                  canLoop: report["canLoop"] as? Bool ?? true, canToggleControls: report["canControls"] as? Bool ?? true,
                  canPictureInPicture: report["canPip"] as? Bool == true, canSave: report["canSave"] as? Bool == true,
                  hasError: report["error"] as? Bool == true)
    }

    /// Finds the media beneath a player overlay without treating an unrelated link, field, or
    /// page-wide overlay as video. The bridge keeps the returned node's backend identifier.
    public static let hitTestFunction = """
    function(x, y, allowOverlay, describe) {
      const doc = this.ownerDocument;
      let media = this;
      while (media && !(media instanceof HTMLMediaElement)) media = media.parentElement || media.getRootNode?.()?.host;
      if (!media && allowOverlay && doc && Number.isFinite(x) && Number.isFinite(y)) {
        const candidates = doc.elementsFromPoint(x, y).filter(node => node instanceof HTMLMediaElement);
        let depth = 0;
        for (let parent = this; parent && parent !== doc.body && parent !== doc.documentElement && depth++ < 8; parent = parent.parentElement) {
          if (parent.matches?.('a, area, input, textarea, button, [contenteditable="true"]')) return null;
          const box = parent.getBoundingClientRect();
          media = candidates.find(candidate => {
            if (!parent.contains(candidate)) return false;
            const videoBox = candidate.getBoundingClientRect();
            return [box.width, box.height, videoBox.width, videoBox.height].every(value => Number.isFinite(value) && value > 0) &&
              box.width <= videoBox.width * 1.25 + 8 && box.height <= videoBox.height * 1.25 + 8;
          });
          if (media) break;
        }
      }
      if (!(media instanceof HTMLMediaElement) || !media.isConnected) return null;
      if (!describe) return media;
      const video = media instanceof HTMLVideoElement;
      const source = media.currentSrc || media.src || null;
      return {
        kind: video ? 'video' : 'audio', paused: media.paused, loop: media.loop,
        controls: media.controls, error: !!media.error,
        pip: doc.pictureInPictureElement === media || media.webkitPresentationMode === 'picture-in-picture',
        canPip: video && !media.disablePictureInPicture && media.readyState > 0 &&
          ((!!doc.pictureInPictureEnabled && typeof media.requestPictureInPicture === 'function') ||
           !!media.webkitSupportsPresentationMode?.('picture-in-picture')),
        canSave: !!source && /^(https?):/.test(source), source
      };
    }
    """

    /// Engines supply the actions; Browsing supplies their localized titles and position.
    public func items(perform: @escaping (EngineContextMenuMediaAction) -> Void) -> [NSMenuItem] {
        func item(_ action: EngineContextMenuMediaAction, enabled: Bool = true, checked: Bool = false) -> NSMenuItem {
            let item = EngineActionMenuItem("", isEnabled: enabled) { perform(action) }
            item.identifier = action.identifier
            item.state = checked ? .on : .off
            return item
        }
        var items = [item(.playPause, enabled: !hasError), item(.loop, enabled: canLoop, checked: isLooping)]
        if kind == .video {
            items += [item(.controls, enabled: canToggleControls, checked: showsControls),
                      item(.pictureInPicture, enabled: canPictureInPicture || isInPictureInPicture),
                      item(.fullscreen, enabled: !hasError)]
        }
        return items
    }
}

public enum EngineContextMenuMediaAction: String, CaseIterable, Sendable {
    case playPause, loop, controls, pictureInPicture, fullscreen

    public var identifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("ARCHEngine.contextMenu.media." + rawValue)
    }

    /// A function called with the clicked node as `this`, in an isolated world with user activation.
    /// It never substitutes another video when the original node disappeared.
    public var function: String {
        let action: String
        switch self {
        case .playPause: action = "if (media.paused) await media.play(); else media.pause();"
        case .loop: action = "media.loop = !media.loop;"
        case .controls: action = "media.controls = !media.controls;"
        case .pictureInPicture:
            action = "return await (\(EnginePictureInPictureScript.toggleVideo))(media);"
        case .fullscreen:
            action = """
            if (media.ownerDocument.fullscreenElement) await media.ownerDocument.exitFullscreen();
            else if (typeof media.requestFullscreen === 'function') await media.requestFullscreen();
            else if (typeof media.webkitEnterFullscreen === 'function') media.webkitEnterFullscreen();
            else return false;
            """
        }
        return """
        async function() {
          let media = this;
          while (media && !(media instanceof HTMLMediaElement)) media = media.parentElement || media.getRootNode?.()?.host;
          if (!media?.isConnected) return false;
          try { \(action) return true; } catch { return false; }
        }
        """
    }
}
