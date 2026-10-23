// Objective-C interface to the Chromium Embedded Framework (CEF). Swift sees only these types. The C++ API stays inside the bridge.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The application class required by CEF. Create it with `sharedApplication` before any other use of `NSApplication`.
@interface ARCHCEFApplication : NSApplication
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
@end

/// CEF's global cookie manager, which every browser in the app shares. Use after `ARCHCEFRuntime` initializes.
@interface ARCHCEFCookieStore : NSObject
/// Calls `completion` once on the main thread with every stored cookie, or with none when the store cannot be read.
+ (void)visitAllCookies:(void (^)(NSArray<ARCHCEFCookie *> *cookies))completion;
/// Stores `cookie` as if `url` had set it. The URL must belong to the cookie's domain.
+ (void)setCookie:(ARCHCEFCookie *)cookie forURL:(NSString *)url;
/// Stores each cookie as if the URL at the same index had set it, then calls `completion` once on the main thread.
+ (void)setCookies:(NSArray<ARCHCEFCookie *> *)cookies forURLs:(NSArray<NSString *> *)urls completion:(void (^)(void))completion;
/// Deletes the cookies named `name` that `url` would send.
+ (void)deleteCookiesForURL:(NSString *)url name:(NSString *)name;
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

@protocol ARCHCEFBrowserDelegate <NSObject>
- (void)cefBrowserDidCreateView;
- (void)cefBrowserDidChangeTitle:(NSString *)title;
- (void)cefBrowserDidChangeURL:(NSString *)url;
- (void)cefBrowserDidChangeLoadingState:(BOOL)isLoading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)cefBrowserDidChangeFaviconURLs:(NSArray<NSString *> *)urls;
/// Reports the search started by `findText:forward:matchCase:findNext:`. `finalUpdate` marks the last report for that request.
- (void)cefBrowserDidFindMatches:(NSInteger)count activeMatchOrdinal:(NSInteger)activeMatchOrdinal finalUpdate:(BOOL)finalUpdate;
- (void)cefBrowserDidRequestPopupWithURL:(NSString *)url;
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
/// Reports that the page's renderer process has exited. The page stays blank until it loads again.
- (void)cefBrowserRenderProcessDidTerminate;
/// Asks for a user name and password for a server or proxy that requires HTTP authentication. `scheme` is lowercase, such as `basic` or `digest`. Call `completion` once, with a nil user name to cancel.
- (void)cefBrowserDidReceiveAuthenticationChallengeForHost:(NSString *)host
                                                       port:(int)port
                                                      realm:(NSString *)realm
                                                     scheme:(NSString *)scheme
                                                  originURL:(NSString *)originURL
                                                    isProxy:(BOOL)isProxy
                                                 completion:(void (^)(NSString *_Nullable user, NSString *_Nullable password))completion;
@end

@interface ARCHCEFRuntime : NSObject
/// Loads the framework from `frameworkPath` and initializes CEF. The main run loop drives CEF's external message pump.
+ (BOOL)initializeWithFrameworkPath:(NSString *)frameworkPath
                         helperPath:(nullable NSString *)helperPath
                          cachePath:(NSString *)cachePath;
+ (BOOL)isInitialized;
+ (void)shutdown;
/// Helper process entry point. Returns the process exit code.
+ (int)runHelperWithArgc:(int)argc argv:(char *_Nonnull *_Nonnull)argv;
@end

/// One browser embedded as a child of `parentView`. CEF adds its own view inside `parentView`.
@interface ARCHCEFBrowser : NSObject
- (instancetype)initWithParentView:(NSView *)parentView
                               url:(NSString *)url
                          delegate:(id<ARCHCEFBrowserDelegate>)delegate;
@property (nonatomic, readonly, nullable) NSView *browserView;
/// Whether a download this browser started is still in progress. CEF stops such downloads when the browser closes.
@property (nonatomic, readonly) BOOL hasDownloadsInProgress;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly, copy) NSString *currentURL;
@property (nonatomic, readonly, copy) NSString *title;
/// Chromium's zoom level. 0 is the default size; each level scales the page by a factor of 1.2.
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
- (void)findText:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext;
/// Ends the current search and keeps the active match selected.
- (void)stopFinding;
/// Opens the system print dialog for the current page.
- (void)print;
/// Renders the current page to PDF data. Passes `nil` when printing fails or no browser exists.
- (void)printToPDFWithCompletion:(void (^)(NSData *_Nullable data))completion;
/// Captures the page as PNG data through the DevTools protocol. `beyondViewport` captures the whole scrollable page.
- (void)captureScreenshotBeyondViewport:(BOOL)beyondViewport
                             completion:(void (^)(NSData *_Nullable pngData))completion NS_SWIFT_NAME(captureScreenshot(beyondViewport:completion:));
- (void)close;
/// Runs the page's `beforeunload` handlers, then closes the browser unless the user chooses to stay. `completion` reports which.
- (void)tryCloseWithCompletion:(void (^)(BOOL closing))completion;
@end

NS_ASSUME_NONNULL_END
