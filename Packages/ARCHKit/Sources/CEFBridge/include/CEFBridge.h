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

/// Permissions a page can ask for. A request may combine several.
typedef NS_OPTIONS(NSUInteger, ARCHCEFPermission) {
    ARCHCEFPermissionCamera = 1 << 0,
    ARCHCEFPermissionMicrophone = 1 << 1,
    ARCHCEFPermissionScreenCapture = 1 << 2,
    ARCHCEFPermissionGeolocation = 1 << 3,
    ARCHCEFPermissionNotifications = 1 << 4,
    ARCHCEFPermissionClipboard = 1 << 5,
    ARCHCEFPermissionMidi = 1 << 6,
};

/// One download reported by the engine. The values are refreshed before each `cefBrowserDidUpdateDownload:` call.
@interface ARCHCEFDownload : NSObject
@property (nonatomic, readonly) uint32_t identifier;
@property (nonatomic, readonly, copy) NSString *url;
/// The destination once the engine has chosen it.
@property (nonatomic, readonly, copy, nullable) NSString *path;
@property (nonatomic, readonly) int64_t receivedBytes;
@property (nonatomic, readonly) int64_t totalBytes;
@property (nonatomic, readonly) ARCHCEFDownloadState state;
/// A request made before the engine reports the first update is applied with that update.
- (void)pause;
- (void)resume;
- (void)cancel;
@end

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
/// Asks where to save a download. Call `decision` with the full destination path, or with `nil` and `showDialog` to let the engine show its Save As dialog.
- (void)cefBrowserDidStartDownload:(ARCHCEFDownload *)download
                     suggestedName:(NSString *)suggestedName
                          decision:(void (^)(NSString *_Nullable path, BOOL showDialog))decision;
- (void)cefBrowserDidUpdateDownload:(ARCHCEFDownload *)download;
/// Asks whether `origin` may use `permissions`. The decision applies to every permission in the request.
- (void)cefBrowserDidRequestPermissions:(ARCHCEFPermission)permissions
                             fromOrigin:(NSString *)origin
                               decision:(void (^)(BOOL allow))decision;
/// The page's renderer process exited. The page is blank until it loads again.
- (void)cefBrowserRenderProcessDidTerminate;
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
@end

NS_ASSUME_NONNULL_END
