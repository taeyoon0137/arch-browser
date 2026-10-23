// Objective-C interface to the Chromium Embedded Framework (CEF). Swift sees only these types. The C++ API stays inside the bridge.
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The application class required by CEF. Create it with `sharedApplication` before any other use of `NSApplication`.
@interface ARCHCEFApplication : NSApplication
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
