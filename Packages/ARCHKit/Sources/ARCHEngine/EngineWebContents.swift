import AppKit
import Foundation

/// How a new web contents starts. Its engine is that of the browser that creates it.
public struct EngineWebContentsConfiguration: Sendable {
    public var initialURL: URL?
    /// Page state that an earlier web contents of the same engine reported as `restorableState`. The engine restores it in place of loading `initialURL` when it can.
    public var restorableState: Data?
    /// The scripts that run in each new document, from the first one on. A web contents a page opens starts with its opener's scripts.
    public var pageScripts: [EnginePageScript]
    public init(initialURL: URL? = nil, restorableState: Data? = nil, pageScripts: [EnginePageScript] = []) {
        self.initialURL = initialURL
        self.restorableState = restorableState
        self.pageScripts = pageScripts
    }
}

public struct EngineFindResult: Hashable, Sendable {
    public var activeMatchOrdinal: Int
    public var numberOfMatches: Int
    public init(activeMatchOrdinal: Int, numberOfMatches: Int) {
        self.activeMatchOrdinal = activeMatchOrdinal
        self.numberOfMatches = numberOfMatches
    }
}

public protocol EngineBackForwardListItem: AnyObject {
    var url: URL { get }
    var title: String { get }
}

public protocol EngineBackForwardList: AnyObject {
    /// The earlier pages, oldest first.
    var backList: [any EngineBackForwardListItem] { get }
}

public protocol EngineNavigationController: AnyObject {
    var backForwardList: any EngineBackForwardList { get }
    func load(_ request: URLRequest)
    func reload()
    func reloadWithoutCache()
    func stop()
    func goBack()
    func goForward()
    /// Loads an earlier or later page from this controller's list. Ignores the current page and items from other lists.
    func go(to item: any EngineBackForwardListItem)
}

/// One tab: state, navigation, find, page scripts, capture, and media.
public protocol EngineWebContents: AnyObject {
    var engineKind: EngineKind { get }
    var view: NSView { get }

    var url: URL? { get }
    var title: String { get }
    var favicon: NSImage? { get }
    var isLoading: Bool { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    /// The page's state, such as its back-forward list, as opaque data the same engine restores through `EngineWebContentsConfiguration.restorableState`. `nil` when the engine cannot restore it.
    var restorableState: Data? { get }
    /// Whether a media element in the page plays sound that is not muted. Sound from Web Audio, or from media elements outside the document or inside shadow roots, does not count.
    var isAudible: Bool { get }
    /// Whether the page uses the camera or the microphone, also while the page has muted it. Read when needed; no delegate call reports changes.
    var isCapturingMedia: Bool { get }
    /// Whether a video of the page plays in the system's picture-in-picture window, whose window closes with the page, also while the video is paused or muted. Read when needed; no delegate call reports changes.
    var isInPictureInPicture: Bool { get }
    var zoomFactor: Double { get set }

    var navigationController: any EngineNavigationController { get }
    var mediaSession: any EngineMediaSession { get }
    var uiDelegate: (any EngineWebContentsUIDelegate)? { get set }
    var navigationDelegate: (any EngineWebContentsNavigationDelegate)? { get set }

    func find(_ text: String, forward: Bool, matchCase: Bool, completion: @escaping (EngineFindResult) -> Void)
    func stopFind()
    /// Receives what the page scripts send.
    var pageScriptDelegate: (any EnginePageScriptDelegate)? { get set }
    /// Replaces the scripts that run in each new document, from the next document on. On WebKit, a web contents and those its pages open share one set, so replacing it in one replaces it in all.
    func setPageScripts(_ scripts: [EnginePageScript])
    /// Names the set of page scripts that `setPageScripts(_:)` replaces: web contents with the same identifier share one, as on WebKit a web contents and those its pages open do.
    var pageScriptListID: ObjectIdentifier { get }
    /// Calls a JavaScript function expression, such as `(channel) => …`, with the channel of `world` in the main frame's current document, opening one there if the world has none, and passes the string the function returns, or nil for any other value. Fails when the function throws or the main frame has no document to run it in.
    func executeJavaScript(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void)
    /// Runs as `executeJavaScript(_:inWorld:completion:)` but without the user's gesture. A gesture would give user activation to page handlers for events the script dispatches, as with a one-time plugin script.
    /// An engine that cannot prevent that activation runs nothing and fails with `EngineUserGestureError`. WebKit uses a private evaluation member only while the private API flags allow plugin page runs.
    func executeJavaScriptWithoutUserGesture(_ script: String, inWorld world: String, completion: @escaping (Result<String?, Error>) -> Void)
    /// Delivers JSON text to a world's channel listeners in the main frame's current document, without the user's gesture.
    /// An engine that can deliver only with a gesture sends nothing and throws `EngineUserGestureError`, since listeners and page handlers for their events would receive user activation.
    /// With no listeners, nothing happens. WebKit uses private evaluation only while the private API flags allow plugin page runs.
    func postPageScriptMessage(_ json: String, toWorld world: String) throws
    /// Reads the main frame's visible text, up to `limit` characters, with its address, title, language, and selection. Fields and editable areas are never read. Fails with `EngineReadableContentError.unreadable` when the page has no document a script can read.
    func readableContent(limit: Int, completion: @escaping (Result<EngineReadableContent, Error>) -> Void)
    func captureViewport(completion: @escaping (NSImage?) -> Void)
    func captureFullPage(completion: @escaping (NSImage?) -> Void)
    /// Renders the page as a paginated PDF on the system's default paper with the page's print styles, for printing and export.
    func createPDF(completion: @escaping (Result<Data, Error>) -> Void)
    /// Ends the page's fullscreen. WebKit ends the page's other media presentations with it, picture in picture included.
    func exitFullscreen()
    /// Starts a download of the address as if the page had started one, so it reaches the download delegate as any download does.
    func download(_ url: URL)
    /// Asks the page's video to enter picture in picture as from the user's own act, or to leave it when one of the page's videos shows there; false when the page has no video, refuses, or does not answer within five seconds. The script runs in a world of the engine's own, apart from the page's scripts, though the page's own event handlers still run while the activation lasts.
    func togglePictureInPicture(completion: @escaping (Bool) -> Void)
    /// Whether closing this web contents now would stop downloads it started. Only Chromium ties downloads to the page that started them.
    var closingStopsDownloads: Bool { get }
    /// Runs the page's `beforeunload` handlers and reports whether the page agreed to close. An engine that cannot run them reports true at once.
    func tryToClose(completion: @escaping (Bool) -> Void)
    /// Tier 2 capability. nil when the engine does not support it.
    var devTools: (any EngineDevTools)? { get }
    /// Tier 2 capability: input that reaches the page as the user's own. nil when the engine offers none.
    var input: (any EngineInput)? { get }
}

public extension EngineWebContents {
    func download(_ url: URL) {}
    func togglePictureInPicture(completion: @escaping (Bool) -> Void) { completion(false) }
    /// A web contents without trusted input, such as a stand-in that has no page yet, offers none.
    var input: (any EngineInput)? { nil }
    /// A web contents keeps its own page scripts unless its engine shares them.
    var pageScriptListID: ObjectIdentifier { ObjectIdentifier(self) }
}

/// The script that `togglePictureInPicture` runs, in an isolated world so that the page cannot replace the functions it calls. It looks in the page and its same-origin frames: a video already in picture in picture leaves it; otherwise the playing video, or else the largest one with data, enters it.
public enum EnginePictureInPictureScript {
    public static let toggle = """
    (async () => {
      const documents = [];
      const collect = doc => {
        documents.push(doc);
        for (const frame of doc.querySelectorAll('iframe, frame')) {
          try { if (frame.contentDocument) collect(frame.contentDocument); } catch {}
        }
      };
      collect(document);
      const settle = request => Promise.race([
        request.then(() => true, () => false),
        new Promise(resolve => setTimeout(() => resolve(false), 5000)),
      ]);
      const shown = documents.find(doc => doc.pictureInPictureElement);
      if (shown) return settle(shown.exitPictureInPicture());
      const videos = documents.flatMap(doc => [...doc.querySelectorAll('video')])
        .filter(video => video.readyState > 0 && !video.disablePictureInPicture);
      const area = video => { const box = video.getBoundingClientRect(); return box.width * box.height; };
      const video = videos.find(video => !video.paused && !video.ended) || videos.sort((a, b) => area(b) - area(a))[0];
      if (!video || !video.requestPictureInPicture) return false;
      return settle(video.requestPictureInPicture());
    })()
    """
}

public protocol EngineDevTools: AnyObject {
    var isOpen: Bool { get }
    /// The view the tools fill while they are open, for the app to place beside the page or in a window of its own.
    var view: NSView? { get }
    /// Whether the app chooses where the tools go. An engine that attaches its tools inside the page's view returns false; its tools have their own docking controls.
    var isPlacedByApp: Bool { get }
    /// Called when the tools open in a view or close.
    var didChangeView: (() -> Void)? { get set }
    func open()
    func close()
}

/// Input that the engine delivers to the page as the user's own: the page's handlers see its events with `isTrusted` true, and the page's default actions follow as for the user's mouse and keyboard. The agents' action tools use it when a tab offers it (`docs/agents.md`, Engine members).
///
/// Points are in the page's viewport, in points from the top-left corner of the area that shows the page. An element's box from `getBoundingClientRect()`, in CSS pixels, maps to it as `(x - visualViewport.offsetLeft) * visualViewport.scale * zoomFactor`, and likewise for `y`.
///
/// Each method sends all its events or throws `EngineInputError` and sends none. The page handles events in order after the method returns.
/// The engine finds the element under each pointer event, or the focused element for each key and text, when the page handles it.
/// A page may move an element under the point or move focus after the caller checks it. A caller that must act on one element checks the target in the event itself (`docs/agents.md`, Actions).
public protocol EngineInput: AnyObject {
    /// Moves the pointer to `point` with no button pressed.
    func movePointer(to point: CGPoint, modifiers: EngineInputModifiers) throws
    /// Presses and releases the primary button at `point` `count` times, from 1 to 3, as a single, double, or triple click does. No pointer move goes first, so the page gets no event between a caller's check of what lies at the point and the press; the press itself makes the element under it the hovered one. Engines refuse Control, with which a click opens the context menu.
    func click(at point: CGPoint, count: Int, modifiers: EngineInputModifiers) throws
    /// Turns the wheel with the pointer at `point` by `deltaX` and `deltaY` points, signed as DOM's `WheelEvent`: positive values scroll right and down. Each delta is rounded to whole points and clamped to `EngineWheelTurn.maximumDelta` either way; engines refuse a delta that is not finite.
    func scroll(at point: CGPoint, deltaX: Double, deltaY: Double, modifiers: EngineInputModifiers) throws
    /// Presses and releases a key in the page's focused element, or in its document when no element has focus.
    func press(_ key: EngineKey, modifiers: EngineInputModifiers) throws
    /// Inserts text at the selection of the page's focused element, as an input method commits it: the page receives input events, and on Chromium a keypress for each character, but no keydown or keyup. Engines refuse text with a line break or a control character, which can submit a form as Enter does; `press(.enter, modifiers:)` types one. Nothing is inserted while no editable element has focus.
    func insertText(_ text: String) throws
}

/// Why an `EngineInput` method sent nothing.
public enum EngineInputError: Error, Equatable, Sendable {
    /// The page's view is in no window, as for a tab that no window shows.
    case notInWindow
    /// The point lies outside the area that shows the page.
    case outsideView
    /// The engine has not created the page yet, or it has closed.
    case noPage
    /// The input needs the page's window to be the key window, or a key needs the page to have its window's keyboard focus, and it does not.
    case notFocused
    /// The engine does not deliver this input as the user's own, such as a key combination, a character without a key, text with a line break or a control character, a click with Control or a count outside 1 to 3, or a wheel delta that is not finite.
    case unsupported
}

/// The whole-point deltas that both adapters send for `EngineInput.scroll`, within the range that every engine's wheel event holds.
public struct EngineWheelTurn: Hashable, Sendable {
    /// The largest delta either way, in points: many times any page's height, so a turn by it reaches the end of a scrolling area, and far inside the 32-bit range of the engines' wheel events.
    public static let maximumDelta = 100_000
    public var deltaX: Int
    public var deltaY: Int

    /// Rounds and clamps each delta; throws `EngineInputError.unsupported` for one that is not finite.
    public init(deltaX: Double, deltaY: Double) throws {
        guard deltaX.isFinite, deltaY.isFinite else { throw EngineInputError.unsupported }
        let limit = Double(Self.maximumDelta)
        self.deltaX = Int(min(max(deltaX, -limit), limit).rounded())
        self.deltaY = Int(min(max(deltaY, -limit), limit).rounded())
    }
}

public struct EngineInputModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
    public static let shift = EngineInputModifiers(rawValue: 1 << 0)
    public static let control = EngineInputModifiers(rawValue: 1 << 1)
    public static let option = EngineInputModifiers(rawValue: 1 << 2)
    public static let command = EngineInputModifiers(rawValue: 1 << 3)
}

/// A key of the US keyboard layout that `EngineInput.press(_:modifiers:)` presses.
public enum EngineKey: Hashable, Sendable {
    case enter, tab, escape, backspace, delete, space
    case arrowUp, arrowDown, arrowLeft, arrowRight, home, end, pageUp, pageDown
    /// The key that types this character without modifiers: a lowercase letter, a digit, or one of `` ` - = [ ] \ ; ' , . / ``. Any other character has no key, and `stroke(with:)` returns nil for it.
    case character(Character)

    /// The key that DOM's `KeyboardEvent.key` names, such as `Enter`, `ArrowUp`, `" "`, or a letter in either case; nil for a name without a key here.
    public init?(domKey: String) {
        if let key = Self.namedKeys[domKey] {
            self = key
        } else if domKey.count == 1, let character = domKey.lowercased().first, Self.characterKeys[character] != nil {
            self = .character(character)
        } else {
            return nil
        }
    }

    /// The virtual key code of the US layout's key that types `character`, with or without Shift; nil for a character that no such key types, such as a space, a line break, or an accented letter.
    public static func keyCode(typing character: Character) -> UInt16? {
        characterKeys[character]?.keyCode ?? characterKeys.first { $0.value.shifted == character }?.value.keyCode
    }

    /// How macOS describes pressing the key with `modifiers`, from which both adapters build their events; nil for a character without a key on the US layout.
    public func stroke(with modifiers: EngineInputModifiers) -> EngineKeyStroke? {
        let keyCode: UInt16, character: Character
        switch self {
        case .enter: (keyCode, character) = (0x24, "\r")
        case .tab: (keyCode, character) = (0x30, "\t")
        case .escape: (keyCode, character) = (0x35, "\u{1B}")
        case .backspace: (keyCode, character) = (0x33, "\u{7F}")
        case .delete: (keyCode, character) = (0x75, "\u{F728}")
        case .space: (keyCode, character) = (0x31, " ")
        case .arrowUp: (keyCode, character) = (0x7E, "\u{F700}")
        case .arrowDown: (keyCode, character) = (0x7D, "\u{F701}")
        case .arrowLeft: (keyCode, character) = (0x7B, "\u{F702}")
        case .arrowRight: (keyCode, character) = (0x7C, "\u{F703}")
        case .home: (keyCode, character) = (0x73, "\u{F729}")
        case .end: (keyCode, character) = (0x77, "\u{F72B}")
        case .pageUp: (keyCode, character) = (0x74, "\u{F72C}")
        case .pageDown: (keyCode, character) = (0x79, "\u{F72D}")
        case .character(let typed):
            guard let key = Self.characterKeys[typed] else { return nil }
            (keyCode, character) = (key.keyCode, typed)
        }
        var unmodified = character
        if modifiers.contains(.shift), case .character = self {
            unmodified = Self.characterKeys[character]?.shifted ?? character
        }
        var modified = unmodified
        if modifiers.contains(.control), case .character = self, character.isLetter, let ascii = character.asciiValue {
            modified = Character(Unicode.Scalar(ascii & 0x1F))
        }
        let typesCharacter = switch self {
        case .enter, .space, .character: modifiers.isDisjoint(with: [.command, .control])
        default: false
        }
        return EngineKeyStroke(keyCode: keyCode, characters: String(modified), charactersIgnoringModifiers: String(unmodified), typesCharacter: typesCharacter)
    }

    private static let namedKeys: [String: EngineKey] = [
        "Enter": .enter, "Tab": .tab, "Escape": .escape, "Backspace": .backspace, "Delete": .delete, " ": .space,
        "ArrowUp": .arrowUp, "ArrowDown": .arrowDown, "ArrowLeft": .arrowLeft, "ArrowRight": .arrowRight,
        "Home": .home, "End": .end, "PageUp": .pageUp, "PageDown": .pageDown,
    ]

    /// The character keys of the US layout by the character each types: the key's code and the character it types with Shift.
    private static let characterKeys: [Character: (keyCode: UInt16, shifted: Character)] = [
        "a": (0x00, "A"), "s": (0x01, "S"), "d": (0x02, "D"), "f": (0x03, "F"), "h": (0x04, "H"), "g": (0x05, "G"), "z": (0x06, "Z"),
        "x": (0x07, "X"), "c": (0x08, "C"), "v": (0x09, "V"), "b": (0x0B, "B"), "q": (0x0C, "Q"), "w": (0x0D, "W"), "e": (0x0E, "E"),
        "r": (0x0F, "R"), "y": (0x10, "Y"), "t": (0x11, "T"), "1": (0x12, "!"), "2": (0x13, "@"), "3": (0x14, "#"), "4": (0x15, "$"),
        "6": (0x16, "^"), "5": (0x17, "%"), "=": (0x18, "+"), "9": (0x19, "("), "7": (0x1A, "&"), "-": (0x1B, "_"), "8": (0x1C, "*"),
        "0": (0x1D, ")"), "]": (0x1E, "}"), "o": (0x1F, "O"), "u": (0x20, "U"), "[": (0x21, "{"), "i": (0x22, "I"), "p": (0x23, "P"),
        "l": (0x25, "L"), "j": (0x26, "J"), "'": (0x27, "\""), "k": (0x28, "K"), ";": (0x29, ":"), "\\": (0x2A, "|"), ",": (0x2B, "<"),
        "/": (0x2C, "?"), "n": (0x2D, "N"), "m": (0x2E, "M"), ".": (0x2F, ">"), "`": (0x32, "~"),
    ]
}

/// One key press as macOS describes it.
public struct EngineKeyStroke: Hashable, Sendable {
    /// The virtual key code, as Carbon's `kVK_` constants number the keys of the US layout.
    public var keyCode: UInt16
    /// The characters AppKit reports for the press: Shift's character on the US layout, and a letter's control character with Control. Option leaves the key's own character.
    public var characters: String
    /// The characters with Shift alone applied, as AppKit's `charactersIgnoringModifiers`.
    public var charactersIgnoringModifiers: String
    /// Whether the press types a character, which DOM reports as a keypress: Enter, Space, and character keys without Command or Control.
    public var typesCharacter: Bool

    public init(keyCode: UInt16, characters: String, charactersIgnoringModifiers: String, typesCharacter: Bool) {
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.typesCharacter = typesCharacter
    }
}
