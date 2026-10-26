// Objective-C interface to the Chromium Embedded Framework (CEF). Swift sees only these types. The C++ API stays inside the bridge.
#import <AppKit/AppKit.h>
#import <IOSurface/IOSurfaceRef.h>

NS_ASSUME_NONNULL_BEGIN

/// The application class required by CEF. Create it with `sharedApplication` before any other use of `NSApplication`.
@interface ARCHCEFApplication : NSApplication
/// Receives each attribute an assistive app sets on the application, before AppKit handles it. Some assistive apps ask a browser to build its accessibility tree this way, through undocumented attributes.
@property (nonatomic, copy, nullable) void (^accessibilityAttributeHandler)(NSString *attribute, id value);
@end

typedef NS_ENUM(NSInteger, ARCHCEFDownloadState) {
    ARCHCEFDownloadStateInProgress,
    ARCHCEFDownloadStateComplete,
    ARCHCEFDownloadStateCanceled,
    ARCHCEFDownloadStateInterrupted,
};

/// Permissions a page can request. One request may combine several permissions.
typedef NS_OPTIONS(NSUInteger, ARCHCEFPermission) {
    ARCHCEFPermissionCamera = 1 << 0,
    ARCHCEFPermissionMicrophone = 1 << 1,
    ARCHCEFPermissionScreenCapture = 1 << 2,
    ARCHCEFPermissionGeolocation = 1 << 3,
    ARCHCEFPermissionNotifications = 1 << 4,
    ARCHCEFPermissionClipboard = 1 << 5,
    ARCHCEFPermissionMidi = 1 << 6,
};

/// The answer Chromium's profile keeps for a site's permission.
typedef NS_ENUM(NSInteger, ARCHCEFPermissionSetting) {
    /// No answer: the site asks again.
    ARCHCEFPermissionSettingAsk,
    ARCHCEFPermissionSettingAllow,
    ARCHCEFPermissionSettingBlock,
};

/// A cookie's `SameSite` attribute, as Chromium keeps it.
typedef NS_ENUM(NSInteger, ARCHCEFCookieSameSite) {
    /// No policy, which Chromium treats as `Lax`.
    ARCHCEFCookieSameSiteUnspecified,
    /// `SameSite=None`, which Chromium accepts only on a secure cookie.
    ARCHCEFCookieSameSiteNoRestriction,
    ARCHCEFCookieSameSiteLax,
    ARCHCEFCookieSameSiteStrict,
};

/// A cookie as the bridge passes it between Swift and CEF's cookie manager.
@interface ARCHCEFCookie : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *value;
@property (nonatomic, copy) NSString *domain;
@property (nonatomic, copy) NSString *path;
/// `nil` for a session cookie.
@property (nonatomic, copy, nullable) NSDate *expires;
@property (nonatomic) BOOL secure;
@property (nonatomic) BOOL httpOnly;
@property (nonatomic) ARCHCEFCookieSameSite sameSite;
@end

/// A Chromium profile: cookies, site storage, caches, and the permission answers it keeps. Browsers of different contexts never share a render process. Until `ARCHCEFRuntime` initializes and once it begins to shut down, calls change nothing and completions still run.
@interface ARCHCEFRequestContext : NSObject
/// The global context, whose profile is `Default` under the root cache path. Ready once the runtime initializes.
@property (class, nonatomic, readonly) ARCHCEFRequestContext *globalContext;
/// A context whose profile lives at `cachePath`, which must be a direct child of the root cache path. Nil for any other path or before the runtime initializes. Browsers can use it at once; cookie, storage, and permission calls wait, in order, until Chromium reports the context and its cookie store initialized.
- (nullable instancetype)initWithCachePath:(NSString *)cachePath;
- (instancetype)init NS_UNAVAILABLE;
/// Calls `completion` once on the main thread with every stored cookie, or with none when the store cannot be read.
- (void)visitAllCookies:(void (^)(NSArray<ARCHCEFCookie *> *cookies))completion;
/// Stores `cookie` as if `url` had set it. The URL must belong to the cookie's domain.
- (void)setCookie:(ARCHCEFCookie *)cookie forURL:(NSString *)url;
/// Stores each cookie as if the URL at the same index had set it, then calls `completion` once on the main thread.
- (void)setCookies:(NSArray<ARCHCEFCookie *> *)cookies forURLs:(NSArray<NSString *> *)urls completion:(void (^)(void))completion;
/// Deletes the cookies named `name` that `url` would send.
- (void)deleteCookiesForURL:(NSString *)url name:(NSString *)name;
/// Deletes every stored cookie that `test` accepts, then calls `completion` once on the main thread after the store has applied the deletions. `test` runs on the main thread.
- (void)deleteCookiesPassingTest:(BOOL (^)(ARCHCEFCookie *cookie))test
                      completion:(void (^)(void))completion NS_SWIFT_NAME(deleteCookies(passingTest:completion:));
/// Clears what each origin, such as `https://example.com`, stores besides cookies: local storage, IndexedDB, Cache Storage, service workers, and file systems. The DevTools protocol's `Storage.clearDataForOrigin` runs in a hidden browser of this context that closes afterwards, so no tab keeps a DevTools client. Calls `completion` once on the main thread.
- (void)clearStorageForOrigins:(NSArray<NSString *> *)origins completion:(void (^)(void))completion NS_SWIFT_NAME(clearStorage(forOrigins:completion:));
/// Sets the answer the profile keeps from Chromium's own permission prompt, which it gives without asking again, for `origin` and each of `permissions` that the prompt can ask for. Screen capture never reaches the prompt, so nothing is kept for it.
- (void)setPermissionSetting:(ARCHCEFPermissionSetting)setting forPermissions:(ARCHCEFPermission)permissions origin:(NSString *)origin;
@end

#pragma mark - Extensions

@class ARCHCEFBrowser;
@class ARCHCEFExtensionWindow;
@class ARCHCEFExtensionPopup;

/// Where an extension's host permissions apply.
typedef NS_ENUM(NSInteger, ARCHCEFExtensionSiteAccess) {
    /// Chromium withholds them: the extension runs on a site only after the user runs its action there or allows it on the site.
    ARCHCEFExtensionSiteAccessOnClick,
    ARCHCEFExtensionSiteAccessOnAllSites,
};

/// What a prompt of the extension runtime asks.
typedef NS_ENUM(NSInteger, ARCHCEFExtensionPromptKind) {
    /// More permissions, as `permissions.request()` asks; the messages are Chromium's sentences for them.
    ARCHCEFExtensionPromptKindPermissions,
    /// An install from the store; the messages are the permissions' sentences.
    ARCHCEFExtensionPromptKindInstall,
    /// A reload of the tab so that blocked actions run; the messages are the names of the waiting extensions.
    ARCHCEFExtensionPromptKindReload,
};

/// An extension installed in a profile, as Chromium's extension runtime lists it.
@interface ARCHCEFExtension : NSObject
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *version;
/// The folder it loads from.
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly) BOOL isEnabled;
@end

/// An extension's action as it shows on one tab.
@interface ARCHCEFExtensionAction : NSObject
@property (nonatomic, readonly, copy) NSString *extensionIdentifier;
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *badgeText;
@property (nonatomic, readonly) BOOL isEnabled;
/// Whether Chromium kept the extension from running on the tab's site, so that it waits for the user to allow it there.
@property (nonatomic, readonly) BOOL wantsSiteAccess;
/// Nil while the icon loads.
@property (nonatomic, readonly, nullable) NSImage *icon;
@end

/// What the app does for the extensions of one request context. Every call comes on the main thread.
@protocol ARCHCEFExtensionsDelegate <NSObject>
/// An extension loaded, was enabled or disabled, unloaded, or was uninstalled.
- (void)cefExtensionsDidChange;
/// The action of the extension changed on `browser`, or on every tab for nil.
- (void)cefExtensionActionDidChange:(NSString *)extensionIdentifier browser:(nullable ARCHCEFBrowser *)browser NS_SWIFT_NAME(cefExtensionActionDidChange(_:browser:));
/// Shows the popup of an action that ran on `browser`: put `popup.view` in a view of the app's at `popup.preferredSize` and return YES, or return NO to close the popup.
- (BOOL)cefExtensionsShouldShowPopup:(ARCHCEFExtensionPopup *)popup forBrowser:(ARCHCEFBrowser *)browser NS_SWIFT_NAME(cefExtensionsShouldShowPopup(_:for:));
/// Asks for a new tab that loads `url`, or the app's new tab page for an empty one, in `window` or a window the app chooses for nil, at `index` among the window's tabs or where the app chooses for -1. Return YES and call `completion` with the tab's browser once a window lists it, or with nil when it did not open; return NO to refuse.
- (BOOL)cefExtensionsOpenTabWithURL:(NSString *)url
                           inWindow:(nullable ARCHCEFExtensionWindow *)window
                             active:(BOOL)active
                              index:(NSInteger)index
                         completion:(void (^)(ARCHCEFBrowser *_Nullable browser))completion NS_SWIFT_NAME(cefExtensionsOpenTab(withURL:in:active:index:completion:));
/// Asks to select the tab, as `tabs.update` with `active` does.
- (void)cefExtensionsActivateBrowser:(ARCHCEFBrowser *)browser NS_SWIFT_NAME(cefExtensionsActivate(_:));
/// Asks to close the tab, as `tabs.remove` does.
- (void)cefExtensionsCloseBrowser:(ARCHCEFBrowser *)browser NS_SWIFT_NAME(cefExtensionsClose(_:));
/// Asks for a new window with a tab for each address, or with the new tab page for none. Return YES and call `completion` with the window once its tabs are set, or with nil; return NO to refuse. The bridge answers CEF once the window lists every one of those tabs, each created, or with no window when one of them closes first.
- (BOOL)cefExtensionsOpenWindowWithURLs:(NSArray<NSString *> *)urls focused:(BOOL)focused completion:(void (^)(ARCHCEFExtensionWindow *_Nullable window))completion NS_SWIFT_NAME(cefExtensionsOpenWindow(withURLs:focused:completion:));
/// Asks the user a prompt for the extension, about `browser` or no tab. Return YES and call `completion` once with the answer, or return NO to refuse. An accepted reload prompt reloads the tab.
- (BOOL)cefExtensionsShowPrompt:(ARCHCEFExtensionPromptKind)kind
                      extension:(NSString *)extensionIdentifier
                        browser:(nullable ARCHCEFBrowser *)browser
                       messages:(NSArray<NSString *> *)messages
                     completion:(void (^)(BOOL accepted))completion NS_SWIFT_NAME(cefExtensionsShowPrompt(_:extension:browser:messages:completion:));
@end

/// The Chromium-format extensions of a request context, through Arch's engine's extension runtime (an experimental CEF API, VI.1). Calls that change extensions, and the list, wait until Chromium has initialized the context and loaded its extensions; actions read now and are empty before then.
@interface ARCHCEFRequestContext (Extensions)
/// The app's side of the context's extensions. Setting it the first time starts the runtime with the bridge's handler, which keeps the delegate weakly.
@property (nonatomic, weak, nullable) id<ARCHCEFExtensionsDelegate> extensionsDelegate;
/// Loads the unpacked extension in the folder at `path`, or reloads it, and keeps loading it at later launches until it is removed. Calls `completion` once on the main thread with Chromium's identifier for it or an error.
- (void)loadExtensionAtPath:(NSString *)path completion:(void (^)(NSString *_Nullable identifier, NSString *_Nullable error))completion NS_SWIFT_NAME(loadExtension(atPath:completion:));
/// Uninstalls the extension and deletes its storage. Its files stay.
- (void)removeExtension:(NSString *)identifier NS_SWIFT_NAME(removeExtension(_:));
- (void)setExtension:(NSString *)identifier enabled:(BOOL)enabled NS_SWIFT_NAME(setExtension(_:enabled:));
- (void)setExtension:(NSString *)identifier siteAccess:(ARCHCEFExtensionSiteAccess)siteAccess NS_SWIFT_NAME(setExtension(_:siteAccess:));
/// Calls `completion` once on the main thread with the installed extensions, or none once the runtime cannot start.
- (void)extensionsWithCompletion:(void (^)(NSArray<ARCHCEFExtension *> *extensions))completion NS_SWIFT_NAME(extensions(completion:));
/// The actions that show on the browser's page, with icons at the window's backing scale.
- (NSArray<ARCHCEFExtensionAction *> *)extensionActionsForBrowser:(ARCHCEFBrowser *)browser scale:(CGFloat)scale NS_SWIFT_NAME(extensionActions(for:scale:));
/// Runs the extension's action on the browser's page, as a click on it does.
- (void)runExtensionAction:(NSString *)identifier inBrowser:(ARCHCEFBrowser *)browser NS_SWIFT_NAME(runExtensionAction(_:in:));
/// Allows the extension on the browser's site, which runs what Chromium kept it from running there.
- (void)grantExtensionSiteAccess:(NSString *)identifier inBrowser:(ARCHCEFBrowser *)browser NS_SWIFT_NAME(grantExtensionSiteAccess(_:in:));
/// A window that extensions see as `normal`, over the AppKit window that holds `contentView`, which must be in one. Its tabs and focus follow its calls; Chromium creates it once the runtime runs.
- (ARCHCEFExtensionWindow *)makeExtensionWindowForView:(NSView *)contentView NS_SWIFT_NAME(makeExtensionWindow(for:));
@end

/// A window that extensions see, with its tabs in order. Chromium answers `windows.remove` with `performClose:` on the AppKit window, and its frame and state come from it.
@interface ARCHCEFExtensionWindow : NSObject
- (instancetype)init NS_UNAVAILABLE;
/// Lists the window's tabs in order, each a browser of the context, with the active one at `activeIndex`, or -1 for none. A browser that Chromium has not created yet joins once it has. A tab that leaves every window by the end of the current task counts as closed.
- (void)setTabs:(NSArray<ARCHCEFBrowser *> *)tabs activeIndex:(NSInteger)activeIndex NS_SWIFT_NAME(setTabs(_:activeIndex:));
/// Whether the window is the one extensions see as focused.
- (void)setFocused:(BOOL)focused;
/// Takes the window away from extensions. Calls after this do nothing.
- (void)close;
@end

/// An action's popup page, which the app shows in a view of its own until it closes.
@interface ARCHCEFExtensionPopup : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSString *extensionIdentifier;
/// The page's view, or nil once the popup has closed.
@property (nonatomic, readonly, nullable) NSView *view;
/// The size the page asks for, in points, between 25 × 25 and 800 × 600.
@property (nonatomic, readonly) NSSize preferredSize;
/// Called when the page asks for another size.
@property (nonatomic, copy, nullable) void (^sizeDidChange)(NSSize size);
/// Called once when the popup closes for any reason, after which its view leaves the app's view.
@property (nonatomic, copy, nullable) void (^didClose)(void);
/// Closes the popup; `didClose` follows.
- (void)close;
@end

/// One download reported by the engine. Values are refreshed before each `cefBrowserDidUpdateDownload:` call.
@interface ARCHCEFDownload : NSObject
@property (nonatomic, readonly) uint32_t identifier;
@property (nonatomic, readonly, copy) NSString *url;
/// The destination after the engine chooses it.
@property (nonatomic, readonly, copy, nullable) NSString *path;
@property (nonatomic, readonly) int64_t receivedBytes;
@property (nonatomic, readonly) int64_t totalBytes;
@property (nonatomic, readonly) ARCHCEFDownloadState state;
/// A request made before the engine's first update takes effect with that update.
- (void)pause;
- (void)resume;
- (void)cancel;
@end

typedef NS_ENUM(NSInteger, ARCHCEFDialogKind) {
    ARCHCEFDialogKindAlert,
    ARCHCEFDialogKindConfirm,
    ARCHCEFDialogKindPrompt,
};

/// Edit commands a page allows in a context menu. One value may combine several.
typedef NS_OPTIONS(NSUInteger, ARCHCEFEditCommand) {
    ARCHCEFEditCommandCut = 1 << 0,
    ARCHCEFEditCommandCopy = 1 << 1,
    ARCHCEFEditCommandPaste = 1 << 2,
    ARCHCEFEditCommandSelectAll = 1 << 3,
};

/// Where a page asked a popup to open, from Chromium's window open disposition.
typedef NS_ENUM(NSInteger, ARCHCEFPopupDisposition) {
    /// A new tab in front, as for a link to a new browsing context.
    ARCHCEFPopupDispositionForegroundTab,
    /// A new tab behind, as for such a link the user clicked with Command.
    ARCHCEFPopupDispositionBackgroundTab,
    /// A window with the features the page asked for, as `window.open` with a size asks.
    ARCHCEFPopupDispositionPopup,
    /// A new window, as for such a link the user clicked with Shift.
    ARCHCEFPopupDispositionWindow,
};

/// Actions the media keys send to a frame's media: the page's Media Session handler runs when the page set one; play and pause otherwise reach the media itself.
typedef NS_ENUM(NSInteger, ARCHCEFMediaAction) {
    ARCHCEFMediaActionPlay,
    ARCHCEFMediaActionPause,
    ARCHCEFMediaActionPreviousTrack,
    ARCHCEFMediaActionNextTrack,
};

/// A script the helper's renderer runs in each new document of a browser, in the page's main world. The scripts of one world share one channel to the app.
@interface ARCHCEFPageScript : NSObject
- (instancetype)initWithWorld:(NSString *)world source:(NSString *)source runsAtDocumentEnd:(BOOL)runsAtDocumentEnd mainFrameOnly:(BOOL)mainFrameOnly NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSString *world;
/// A JavaScript function expression, which the renderer calls with the world's channel.
@property (nonatomic, readonly, copy) NSString *source;
/// Whether the script waits for `DOMContentLoaded`. Otherwise it runs before the page's own scripts.
@property (nonatomic, readonly) BOOL runsAtDocumentEnd;
@property (nonatomic, readonly) BOOL mainFrameOnly;
@end

/// One page in a browser's back-forward list.
@interface ARCHCEFNavigationEntry : NSObject
/// The page's place in the list, from 0 for the oldest.
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly, copy) NSString *url;
@property (nonatomic, readonly, copy) NSString *title;
@end

/// What a context menu opened on, copied from CEF, whose own object lasts only for its callback.
@interface ARCHCEFContextMenuParams : NSObject
/// Where the menu opens, in the coordinates of the browser's parent view.
@property (nonatomic, readonly) NSPoint location;
/// The link's absolute URL, before Chromium replaces disallowed targets with `about:blank#blocked`, so Copy Link keeps the real address. nil without a link.
@property (nonatomic, readonly, copy, nullable) NSString *linkURL;
@property (nonatomic, readonly, copy, nullable) NSString *imageURL;
@property (nonatomic, readonly, copy, nullable) NSString *mediaURL;
@property (nonatomic, readonly, copy) NSString *selectionText;
@property (nonatomic, readonly) BOOL isEditable;
/// Whether the menu opened in the main frame rather than in a frame inside the page.
@property (nonatomic, readonly) BOOL isInMainFrame;
@property (nonatomic, readonly) ARCHCEFEditCommand editCommands;
/// Empty unless the menu opened on a misspelled word in an editable field.
@property (nonatomic, readonly, copy) NSString *misspelledWord;
@property (nonatomic, readonly, copy) NSArray<NSString *> *spellingSuggestions;
@end

@class ARCHCEFBrowser;

@protocol ARCHCEFBrowserDelegate <NSObject>
- (void)cefBrowserDidCreateView;
- (void)cefBrowserDidChangeTitle:(NSString *)title;
- (void)cefBrowserDidChangeURL:(NSString *)url;
- (void)cefBrowserDidChangeLoadingState:(BOOL)isLoading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
/// Reports that the main frame finished loading a document. The loading state, unlike this, also follows the frames inside the page.
- (void)cefBrowserDidFinishLoadingDocument;
- (void)cefBrowserDidChangeFaviconURLs:(NSArray<NSString *> *)urls;
/// Reports the search started by `findText:forward:matchCase:findNext:`. `finalUpdate` marks its last report.
- (void)cefBrowserDidFindMatches:(NSInteger)count activeMatchOrdinal:(NSInteger)activeMatchOrdinal finalUpdate:(BOOL)finalUpdate;
/// Asks whether a popup the page opens now would be adopted through `cefBrowserDidOpenPopup:targetURL:disposition:`. Return NO to stop the popup before CEF creates it.
- (BOOL)cefBrowserCanAdoptPopup;
/// Reports a popup the page opened, which CEF has created in this browser's browsing context, so the page reaches it through the window `window.open` returned and the popup reaches the page through `window.opener`. `targetURL` is the address the page opened, empty when it gave none. Set the popup's `delegate` to keep it. A popup that has none when this returns closes on the next turn of the run loop: CEF owns its page only once the opener shows it, after this callback.
- (void)cefBrowserDidOpenPopup:(ARCHCEFBrowser *)popup targetURL:(NSString *)targetURL disposition:(ARCHCEFPopupDisposition)disposition;
/// Asks whether a navigation or popup to `url` belongs to another app. Return YES to stop it; the delegate then offers the link to that app. `userGesture` is true when the user clicked the link.
- (BOOL)cefBrowserShouldOpenExternallyURL:(NSString *)url userGesture:(BOOL)userGesture;
/// Asks whether a link the user clicked with Shift, which Chromium opens in a new window, may open. Return NO to stop it; with YES it opens as an Alloy style browser opens it: in this browser or, for a link to a new browsing context, as a popup.
- (BOOL)cefBrowserShouldOpenNewWindowWithURL:(NSString *)url;
/// Reports that the browser closed, or that its page closed itself with `window.close()` while one of its downloads needs the browser. The browser then stays open, so the download goes on, until `close` or `tryCloseWithCompletion:`.
- (void)cefBrowserDidClose;
/// Asks whether a download from `url` may start. `hasDocument` is false when the browser never showed a page.
- (BOOL)cefBrowserShouldDownloadURL:(NSString *)url hasDocument:(BOOL)hasDocument;
/// Asks for a download destination. Call `decision` with the full destination path, or with `nil` and `showDialog` to open the engine's Save As dialog.
- (void)cefBrowserDidStartDownload:(ARCHCEFDownload *)download
                     suggestedName:(NSString *)suggestedName
                          decision:(void (^)(NSString *_Nullable path, BOOL showDialog))decision;
- (void)cefBrowserDidUpdateDownload:(ARCHCEFDownload *)download;
/// Asks whether `origin` may use `permissions`. One decision applies to every permission in the request.
- (void)cefBrowserDidRequestPermissions:(ARCHCEFPermission)permissions
                             fromOrigin:(NSString *)origin
                               decision:(void (^)(BOOL allow))decision;
/// Asks the app to show a page's `alert`, `confirm`, or `prompt`. Call `completion` once with whether the user accepted and, for a prompt, the text.
- (void)cefBrowserRunDialog:(ARCHCEFDialogKind)kind
                    message:(NSString *)message
                defaultText:(NSString *)defaultText
                 completion:(void (^)(BOOL accepted, NSString *_Nullable text))completion;
/// Asks whether to leave a page whose `beforeunload` handler asks to stay. Call `completion` once.
- (void)cefBrowserRunLeavePageDialogWithCompletion:(void (^)(BOOL leave))completion;
/// The page's dialogs no longer apply, as after a navigation. Sheets still open for them should close.
- (void)cefBrowserDidResetDialogs;
/// Asks the app to show the page's context menu. The bridge calls this after CEF's current work returns, so CEF keeps running while the menu tracks. Call `completion` once after the menu closes; the bridge calls it itself if the browser closes first.
- (void)cefBrowserRunContextMenu:(ARCHCEFContextMenuParams *)params completion:(void (^)(void))completion;
/// Reports that the page's renderer process has exited. The page stays blank until it loads again.
- (void)cefBrowserRenderProcessDidTerminate;
/// Reports that the page entered or left fullscreen through the Fullscreen API. CEF has already sized the content; the app makes the window's transition and handles Escape.
- (void)cefBrowserDidChangeFullscreen:(BOOL)isFullscreen;
/// Reports the page's theme color after each load: empty when the page declares none, otherwise `#rrggbb` or `rgba(r, g, b, a)` as a canvas writes the color.
- (void)cefBrowserDidChangeThemeColor:(NSString *)color;
/// Reports whether any frame's media elements play sound that is not muted.
- (void)cefBrowserDidChangeAudible:(BOOL)isAudible;
/// Reports a frame's media whenever it changes: the dictionary the media script writes, or nil once the frame has no media that played sound or its document went away.
- (void)cefBrowserDidChangeMedia:(nullable NSDictionary<NSString *, id> *)media frame:(NSString *)frameIdentifier;
/// Reports the view that the developer tools fill once they open. The view stays the same until `cefBrowserDevToolsDidClose`; the app may move it between superviews and windows.
- (void)cefBrowserDevToolsDidOpenView:(NSView *)view;
/// Reports that the developer tools closed. When they close on their own, their front-end has already left the view that `cefBrowserDevToolsDidOpenView:` reported; when the browser closes first, CEF takes it out right after this call. Do not reuse the view: new tools open in a new one.
- (void)cefBrowserDevToolsDidClose;
/// Reports that a video of the page entered picture in picture, which Chromium's own window then does not show. `naturalSize` is the video's size in pixels. `sourceRect` is where the page showed the video, in points from the top left of the browser's view; for a video in a frame of another site's process, it is relative to that frame. Frames follow until `cefBrowserDidStopPictureInPicture`. Another video of the page that enters picture in picture meanwhile takes the first one's place without a new report.
- (void)cefBrowserDidStartPictureInPictureWithNaturalSize:(NSSize)naturalSize sourceRect:(NSRect)sourceRect NS_SWIFT_NAME(cefBrowserDidStartPictureInPicture(naturalSize:sourceRect:));
/// Reports a frame of the video in picture in picture: an IOSurface in BGRA, of which only `contentRect`, in pixels from the surface's top left, holds the video. The surface keeps its contents until three later frames have arrived or `cefBrowserDidStopPictureInPicture` has returned, so it can be displayed without a copy. Retain it to use it after this call.
- (void)cefBrowserDidReceivePictureInPictureFrame:(IOSurfaceRef)surface contentRect:(NSRect)contentRect NS_SWIFT_NAME(cefBrowserDidReceivePictureInPictureFrame(_:contentRect:));
/// Reports whether the video in picture in picture plays, right after its start and whenever that changes. `canPlayPause` is NO when the page offers no play or pause control for the video, as for a camera stream.
- (void)cefBrowserDidChangePictureInPicturePlaying:(BOOL)playing canPlayPause:(BOOL)canPlayPause NS_SWIFT_NAME(cefBrowserDidChangePictureInPicturePlaying(_:canPlayPause:));
/// Reports that picture in picture ended, for any reason: the page ended it, navigated, crashed, or closed, another tab's video took its place, or the app called `closePictureInPicturePausingVideo:`. No frames follow.
- (void)cefBrowserDidStopPictureInPicture;
/// Asks for a user name and password for a server or proxy that requires HTTP authentication. `scheme` is lowercase, such as `basic` or `digest`. Call `completion` once, with a nil user name to cancel.
- (void)cefBrowserDidReceiveAuthenticationChallengeForHost:(NSString *)host
                                                       port:(int)port
                                                      realm:(NSString *)realm
                                                     scheme:(NSString *)scheme
                                                  originURL:(NSString *)originURL
                                                    isProxy:(BOOL)isProxy
                                                 completion:(void (^)(NSString *_Nullable user, NSString *_Nullable password))completion;
/// Reports a value, as JSON text, that a page script sent through the channel of `world` from the frame whose document is at `frameURL`. Call `reply` with the reply's JSON text, or nil for none; the first call settles the script's promise.
- (void)cefBrowserDidReceivePageScriptMessage:(NSString *)json
                                        world:(NSString *)world
                                     frameURL:(NSString *)frameURL
                                  isMainFrame:(BOOL)isMainFrame
                                        reply:(void (^)(NSString *_Nullable json))reply;
@end

@interface ARCHCEFRuntime : NSObject
/// Loads the framework from `frameworkPath` and initializes CEF. The main run loop drives CEF's external message pump.
+ (BOOL)initializeWithFrameworkPath:(NSString *)frameworkPath
                         helperPath:(nullable NSString *)helperPath
                          cachePath:(NSString *)cachePath;
+ (BOOL)isInitialized;
/// Closes every browser, runs CEF's work for up to two seconds while they close, and shuts CEF down. It runs by itself at `NSApplicationWillTerminateNotification`, once the quit is certain.
+ (void)shutdown;
/// The version of the CEF distribution the bridge builds with, which the framework must match, such as `156.0.42-arch-8078.3687+g10ca70a+chromium-156.0.8078.48`.
@property (class, nonatomic, readonly, copy) NSString *cefVersion;
/// Builds the accessibility tree of every browser, now and as browsers open, or stops building it. Assistive apps then read Chromium pages as they read WebKit ones; the tree costs memory and time on every page.
+ (void)setAccessibilityEnabled:(BOOL)enabled;
/// Helper process entry point. Returns the process exit code.
+ (int)runHelperWithArgc:(int)argc argv:(char *_Nonnull *_Nonnull)argv;
@end

/// One browser embedded as a child of `parentView`. CEF adds its own view inside `parentView`. Each popup a page opens is a browser of its own, which the bridge makes and the opener's delegate adopts through `cefBrowserDidOpenPopup:targetURL:disposition:`.
///
/// CEF creates and closes a browser on later tasks. The bridge keeps the object, and with it `parentView` and the view CEF adds, from creation until CEF has created the browser, and from `close` or `tryCloseWithCompletion:` until CEF has closed it, so the app may release the object at any time. Releasing an open browser that the app did not close closes it. CEF never closes the window that shows the browser.
@interface ARCHCEFBrowser : NSObject
/// Creates the browser in `requestContext`, whose profile the page loads in. The renderer runs `pageScripts` from the first document on.
- (instancetype)initWithParentView:(NSView *)parentView
                               url:(NSString *)url
                    requestContext:(ARCHCEFRequestContext *)requestContext
                       pageScripts:(NSArray<ARCHCEFPageScript *> *)pageScripts
                          delegate:(id<ARCHCEFBrowserDelegate>)delegate;
/// The delegate given at creation. A popup has none until its opener's delegate adopts it.
@property (nonatomic, weak, nullable) id<ARCHCEFBrowserDelegate> delegate;
/// The view that the browser's view fills: the one given at creation or, for a popup, a container of its opener's size.
@property (nonatomic, readonly) NSView *parentView;
@property (nonatomic, readonly, nullable) NSView *browserView;
/// Whether a download this browser started is still in progress or interrupted, and not cancelled by the app. CEF stops such downloads when the browser closes, and only this browser can resume an interrupted one.
@property (nonatomic, readonly) BOOL hasDownloadsInProgress;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
/// The back-forward list, oldest first, read from CEF on each access.
@property (nonatomic, readonly) NSArray<ARCHCEFNavigationEntry *> *navigationEntries;
/// The current page's index in `navigationEntries`, or -1 without pages.
@property (nonatomic, readonly) NSInteger currentNavigationEntryIndex;
@property (nonatomic, readonly, copy) NSString *currentURL;
@property (nonatomic, readonly, copy) NSString *title;
/// Chromium's zoom level: 0 is the default size; each level scales the page by 1.2.
@property (nonatomic) double zoomLevel;
/// Whether the page may start downloads. Defaults to `YES`.
@property (nonatomic) BOOL allowsDownloads;
- (void)loadURL:(NSString *)url;
- (void)reload;
- (void)reloadIgnoringCache;
- (void)stopLoading;
- (void)goBack;
- (void)goForward;
- (void)executeJavaScript:(NSString *)script;
/// Evaluates `script` in the main frame's page world and passes the string it evaluates to. `executeJavaScript:` returns nothing, so the page's renderer process runs the script and replies with a process message. Passes nil when the frame has no script context, the script throws or returns another type, the page's process quits, the browser goes, or no reply comes within ten seconds. Calls `completion` once on the main thread.
- (void)evaluateScript:(NSString *)script completion:(void (^)(NSString *_Nullable result))completion;
/// Replaces the page scripts, from each frame's next document on. The renderer processes of the browser's frames get them at once, and each frame created after the change gets them as well. In a renderer process that had none of the browser's frames, such as after a cross-site navigation, the first document may still run the scripts the browser was created with, because CEF does not order the message before it (needs verification).
- (void)setPageScripts:(NSArray<ARCHCEFPageScript *> *)pageScripts;
/// Calls a JavaScript function expression with the channel of `world` in the main frame's current document, opening one there if the world has none. Calls `completion` once on the main thread with whether the function ran without throwing and the string it returned, or with NO when the frame has no script context, the page's process quits, the browser goes, or no reply comes within ten seconds.
- (void)callPageScriptFunction:(NSString *)function
                       inWorld:(NSString *)world
                    completion:(void (^)(BOOL succeeded, NSString *_Nullable result))completion NS_SWIFT_NAME(callPageScriptFunction(_:inWorld:completion:));
/// Delivers a value, as JSON text, to the listeners of a world's channel in the main frame's current document.
- (void)postPageScriptMessage:(NSString *)json toWorld:(NSString *)world NS_SWIFT_NAME(postPageScriptMessage(_:toWorld:));
/// Sends a media action to the frame that reported media through `cefBrowserDidChangeMedia:frame:`. Nothing happens once the frame is gone.
- (void)performMediaAction:(ARCHCEFMediaAction)action inFrame:(NSString *)frameIdentifier NS_SWIFT_NAME(performMediaAction(_:inFrame:));
/// Plays or pauses the video in picture in picture, through the page's Media Session handler when it has one. Does nothing while no video of the page is in picture in picture.
- (void)setPictureInPicturePlaying:(BOOL)playing;
/// Ends picture in picture for the page's video. `pause` pauses the video, as closing the window does; pass NO when the user returns to the page. CEF reports the end through `cefBrowserDidStopPictureInPicture` before this returns. Does nothing while no video of the page is in picture in picture.
- (void)closePictureInPicturePausingVideo:(BOOL)pause NS_SWIFT_NAME(closePictureInPicture(pausingVideo:));
- (void)findText:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext;
/// Ends the search and leaves the active match selected.
- (void)stopFinding;
/// Opens the current page's system print dialog.
- (void)print;
/// Renders the current page as PDF data on the system's default paper size. Passes `nil` if printing fails or no browser exists.
- (void)printToPDFWithCompletion:(void (^)(NSData *_Nullable data))completion;
/// Captures the page as PNG through the DevTools protocol. `beyondViewport` captures the whole scrollable page. Calls `completion` once on the main thread, with nil when the capture fails, the page's process quits, or the browser closes first.
- (void)captureScreenshotBeyondViewport:(BOOL)beyondViewport
                             completion:(void (^)(NSData *_Nullable pngData))completion NS_SWIFT_NAME(captureScreenshot(beyondViewport:completion:));
/// Opens Chromium's developer tools for this browser inside a view that the bridge makes and reports through `cefBrowserDevToolsDidOpenView:`, or focuses the open tools. Does nothing while the tools close, from when `hasDevTools` turns NO until `cefBrowserDevToolsDidClose`.
- (void)showDevTools;
- (void)closeDevTools;
/// Whether this browser's developer tools are open. NO as soon as they start closing.
@property (nonatomic, readonly) BOOL hasDevTools;
/// Leaves the fullscreen the page entered. `willResize` tells CEF that leaving also resizes the view.
- (void)exitFullscreenWillResize:(BOOL)willResize NS_SWIFT_NAME(exitFullscreen(willResize:));
/// Closes the browser without running the page's `beforeunload` handlers. A close before CEF has created the browser takes effect once it has.
- (void)close;
/// Runs the page's `beforeunload` handlers, then closes the browser unless the user chooses to stay. `completion` reports which. Before CEF has created the browser, it reports closing at once and the browser closes once it is created.
- (void)tryCloseWithCompletion:(void (^)(BOOL closing))completion;
/// Loads the page at `index` in the back-forward list. Nothing happens for the current page, an index outside the list, or an entry whose URL is no longer `url`.
- (void)goToNavigationEntryAtIndex:(NSInteger)index url:(NSString *)url NS_SWIFT_NAME(goToNavigationEntry(at:url:));
/// Runs one edit command in the frame the last context menu opened on, or in the focused frame once that frame is gone.
- (void)performEditCommand:(ARCHCEFEditCommand)command NS_SWIFT_NAME(performEditCommand(_:));
/// Replaces the selected misspelled word with `word`.
- (void)replaceMisspellingWithWord:(NSString *)word NS_SWIFT_NAME(replaceMisspelling(withWord:));
@end

NS_ASSUME_NONNULL_END
