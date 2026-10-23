// Initializes the Chromium Embedded Framework (CEF) and runs its message pump. Uses one `CefClient` per embedded browser.
#import "CEFBridge.h"

#include <crt_externs.h>
#include <dispatch/dispatch.h>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_find_handler.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

#pragma mark - NSApplication subclass

@interface ARCHCEFApplication () <CefAppProtocol> {
    BOOL _handlingSendEvent;
}
@end

@implementation ARCHCEFApplication

- (BOOL)isHandlingSendEvent {
    return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
    _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent *)event {
    CefScopedSendingEvent sendingEventScoper;
    [super sendEvent:event];
}

- (void)terminate:(id)sender {
    [ARCHCEFRuntime shutdown];
    [super terminate:sender];
}

@end

#pragma mark - Message pump

// Runs CEF work on the main run loop the way the CEF client sample does: immediately for a delay of zero or less,
// otherwise on a one-shot timer no later than 33 ms, and again at once when a request arrives during a run.
@interface ARCHCEFPump : NSObject
+ (instancetype)shared;
- (void)scheduleWork:(int64_t)delayMilliseconds;
@end

@implementation ARCHCEFPump {
    NSTimer *_timer;
    BOOL _isActive;
    BOOL _reentrancyDetected;
}

static const int64_t kMaxTimerDelayMilliseconds = 1000 / 30;
static const int64_t kTimerDelayPlaceholder = INT64_MAX;

+ (instancetype)shared {
    static ARCHCEFPump *pump;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pump = [[ARCHCEFPump alloc] init]; });
    return pump;
}

- (void)scheduleWork:(int64_t)delayMilliseconds {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self scheduleWork:delayMilliseconds]; });
        return;
    }
    if (delayMilliseconds == kTimerDelayPlaceholder && _timer != nil) {
        return;
    }
    [self killTimer];
    if (delayMilliseconds <= 0) {
        [self doWork];
        return;
    }
    int64_t delay = MIN(delayMilliseconds, kMaxTimerDelayMilliseconds);
    _timer = [NSTimer scheduledTimerWithTimeInterval:delay / 1000.0 target:self selector:@selector(timerFired:) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSEventTrackingRunLoopMode];
}

- (void)timerFired:(NSTimer *)timer {
    [self killTimer];
    [self doWork];
}

- (void)killTimer {
    [_timer invalidate];
    _timer = nil;
}

- (void)doWork {
    if (_isActive) {
        _reentrancyDetected = YES;
        return;
    }
    _reentrancyDetected = NO;
    _isActive = YES;
    CefDoMessageLoopWork();
    _isActive = NO;
    if (_reentrancyDetected) {
        [self scheduleWork:0];
    } else if (_timer == nil) {
        [self scheduleWork:kTimerDelayPlaceholder];
    }
}

@end

#pragma mark - CefApp

namespace {

NSString *ToNSString(const CefString &value) {
    std::string utf8 = value.ToString();
    return [NSString stringWithUTF8String:utf8.c_str()] ?: @"";
}

class BridgeApp : public CefApp, public CefBrowserProcessHandler {
public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        [[ARCHCEFPump shared] scheduleWork:delay_ms];
    }

    // Unsigned development builds lack a stable code identity. The login keychain would therefore prompt for the cookie
    // encryption key on every launch, blocking startup. The mock keychain avoids this until the app is signed.
    void OnBeforeCommandLineProcessing(const CefString &process_type, CefRefPtr<CefCommandLine> command_line) override {
        if (process_type.empty()) {
            command_line->AppendSwitch("use-mock-keychain");
        }
    }

private:
    IMPLEMENT_REFCOUNTING(BridgeApp);
};

bool gInitialized = false;

}  // namespace

#pragma mark - Runtime

@implementation ARCHCEFRuntime

+ (BOOL)initializeWithFrameworkPath:(NSString *)frameworkPath helperPath:(NSString *)helperPath cachePath:(NSString *)cachePath {
    if (gInitialized) {
        return YES;
    }
    NSString *library = [frameworkPath stringByAppendingPathComponent:@"Chromium Embedded Framework"];
    if (!cef_load_library(library.fileSystemRepresentation)) {
        return NO;
    }
    CefMainArgs mainArgs(*_NSGetArgc(), *_NSGetArgv());
    CefSettings settings;
    settings.no_sandbox = true;
    settings.external_message_pump = true;
    CefString(&settings.framework_dir_path) = frameworkPath.UTF8String;
    CefString(&settings.root_cache_path) = cachePath.UTF8String;
    CefString(&settings.cache_path) = cachePath.UTF8String;
    if (helperPath.length > 0) {
        CefString(&settings.browser_subprocess_path) = helperPath.UTF8String;
    }
    CefRefPtr<BridgeApp> app(new BridgeApp);
    if (!CefInitialize(mainArgs, settings, app.get(), nullptr)) {
        return NO;
    }
    gInitialized = true;
    return YES;
}

+ (BOOL)isInitialized {
    return gInitialized;
}

+ (void)shutdown {
    if (!gInitialized) {
        return;
    }
    gInitialized = false;
    CefShutdown();
}

+ (int)runHelperWithArgc:(int)argc argv:(char **)argv {
    CefScopedLibraryLoader libraryLoader;
    if (!libraryLoader.LoadInHelper()) {
        return 1;
    }
    CefMainArgs mainArgs(argc, argv);
    return CefExecuteProcess(mainArgs, nullptr, nullptr);
}

@end

#pragma mark - Browser

@interface ARCHCEFBrowser ()
- (void)handleAfterCreated:(CefRefPtr<CefBrowser>)browser;
- (void)handleTitle:(NSString *)title;
- (void)handleURL:(NSString *)url;
- (void)handleLoadingState:(BOOL)isLoading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)handleFaviconURLs:(NSArray<NSString *> *)urls;
- (void)handleFindResult:(int)count activeMatchOrdinal:(int)activeMatchOrdinal finalUpdate:(BOOL)finalUpdate;
- (void)handlePopup:(NSString *)url;
- (void)handleBeforeClose;
@end

namespace {

// Forwards one browser's CEF callbacks to its `ARCHCEFBrowser`. The owner calls `Detach()` before releasing the client.
class BridgeClient : public CefClient, public CefDisplayHandler, public CefLifeSpanHandler, public CefLoadHandler, public CefFindHandler {
public:
    explicit BridgeClient(ARCHCEFBrowser *owner) : owner_(owner) {}

    void Detach() { owner_ = nil; }

    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        [owner_ handleAfterCreated:browser];
    }

    bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id, const CefString &target_url,
                       const CefString &target_frame_name, CefLifeSpanHandler::WindowOpenDisposition target_disposition,
                       bool user_gesture, const CefPopupFeatures &popupFeatures, CefWindowInfo &windowInfo,
                       CefRefPtr<CefClient> &client, CefBrowserSettings &settings, CefRefPtr<CefDictionaryValue> &extra_info,
                       bool *no_javascript_access) override {
        [owner_ handlePopup:ToNSString(target_url)];
        return true;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        [owner_ handleBeforeClose];
    }

    void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
        [owner_ handleTitle:ToNSString(title)];
    }

    void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &url) override {
        if (frame->IsMain()) {
            [owner_ handleURL:ToNSString(url)];
        }
    }

    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) override {
        [owner_ handleLoadingState:isLoading canGoBack:canGoBack canGoForward:canGoForward];
    }

    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString> &icon_urls) override {
        NSMutableArray<NSString *> *urls = [NSMutableArray arrayWithCapacity:icon_urls.size()];
        for (const CefString &url : icon_urls) {
            [urls addObject:ToNSString(url)];
        }
        [owner_ handleFaviconURLs:urls];
    }

    void OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count, const CefRect &selectionRect, int activeMatchOrdinal,
                      bool finalUpdate) override {
        [owner_ handleFindResult:count activeMatchOrdinal:activeMatchOrdinal finalUpdate:finalUpdate];
    }

private:
    __unsafe_unretained ARCHCEFBrowser *owner_;
    IMPLEMENT_REFCOUNTING(BridgeClient);
};

// Reads the finished PDF into memory and removes the temporary file CEF wrote.
class BridgePdfCallback : public CefPdfPrintCallback {
public:
    explicit BridgePdfCallback(void (^completion)(NSData *_Nullable)) : completion_(completion) {}

    void OnPdfPrintFinished(const CefString &path, bool ok) override {
        NSString *file = ToNSString(path);
        NSData *data = ok ? [NSData dataWithContentsOfFile:file] : nil;
        [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
        completion_(data);
    }

private:
    void (^completion_)(NSData *_Nullable);
    IMPLEMENT_REFCOUNTING(BridgePdfCallback);
};

}  // namespace

@implementation ARCHCEFBrowser {
    CefRefPtr<BridgeClient> _client;
    CefRefPtr<CefBrowser> _browser;
    __weak id<ARCHCEFBrowserDelegate> _delegate;
    NSView *_parentView;
}

@synthesize browserView = _browserView;
@synthesize isLoading = _isLoading;
@synthesize canGoBack = _canGoBack;
@synthesize canGoForward = _canGoForward;
@synthesize currentURL = _currentURL;
@synthesize title = _title;

- (instancetype)initWithParentView:(NSView *)parentView url:(NSString *)url delegate:(id<ARCHCEFBrowserDelegate>)delegate {
    self = [super init];
    if (!self) {
        return nil;
    }
    _parentView = parentView;
    _delegate = delegate;
    _currentURL = [url copy];
    _title = @"";
    _client = new BridgeClient(self);

    CefWindowInfo windowInfo;
    NSRect bounds = parentView.bounds;
    windowInfo.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(parentView),
                          CefRect(0, 0, (int)NSWidth(bounds), (int)NSHeight(bounds)));
    CefBrowserSettings settings;
    CefBrowserHost::CreateBrowser(windowInfo, _client, CefString(url.UTF8String), settings, nullptr, nullptr);
    return self;
}

- (void)dealloc {
    if (_client) {
        _client->Detach();
    }
}

- (void)handleAfterCreated:(CefRefPtr<CefBrowser>)browser {
    _browser = browser;
    NSView *view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    view.frame = _parentView.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _browserView = view;
    [_delegate cefBrowserDidCreateView];
}

- (void)handleTitle:(NSString *)title {
    _title = [title copy];
    [_delegate cefBrowserDidChangeTitle:title];
}

- (void)handleURL:(NSString *)url {
    _currentURL = [url copy];
    [_delegate cefBrowserDidChangeURL:url];
}

- (void)handleLoadingState:(BOOL)isLoading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward {
    _isLoading = isLoading;
    _canGoBack = canGoBack;
    _canGoForward = canGoForward;
    [_delegate cefBrowserDidChangeLoadingState:isLoading canGoBack:canGoBack canGoForward:canGoForward];
}

- (void)handleFaviconURLs:(NSArray<NSString *> *)urls {
    [_delegate cefBrowserDidChangeFaviconURLs:urls];
}

- (void)handleFindResult:(int)count activeMatchOrdinal:(int)activeMatchOrdinal finalUpdate:(BOOL)finalUpdate {
    [_delegate cefBrowserDidFindMatches:count activeMatchOrdinal:activeMatchOrdinal finalUpdate:finalUpdate];
}

- (void)handlePopup:(NSString *)url {
    [_delegate cefBrowserDidRequestPopupWithURL:url];
}

- (void)handleBeforeClose {
    _browser = nullptr;
    _browserView = nil;
    [_delegate cefBrowserDidClose];
}

- (void)loadURL:(NSString *)url {
    if (_browser) {
        _browser->GetMainFrame()->LoadURL(CefString(url.UTF8String));
    }
}

- (void)reload {
    if (_browser) {
        _browser->Reload();
    }
}

- (void)reloadIgnoringCache {
    if (_browser) {
        _browser->ReloadIgnoreCache();
    }
}

- (void)stopLoading {
    if (_browser) {
        _browser->StopLoad();
    }
}

- (void)goBack {
    if (_browser) {
        _browser->GoBack();
    }
}

- (void)goForward {
    if (_browser) {
        _browser->GoForward();
    }
}

- (void)executeJavaScript:(NSString *)script {
    if (_browser) {
        _browser->GetMainFrame()->ExecuteJavaScript(CefString(script.UTF8String), _browser->GetMainFrame()->GetURL(), 0);
    }
}

- (double)zoomLevel {
    return _browser ? _browser->GetHost()->GetZoomLevel() : 0;
}

- (void)setZoomLevel:(double)zoomLevel {
    if (_browser) {
        _browser->GetHost()->SetZoomLevel(zoomLevel);
    }
}

- (void)findText:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext {
    if (_browser) {
        _browser->GetHost()->Find(CefString(text.UTF8String), forward, matchCase, findNext);
    }
}

- (void)stopFinding {
    if (_browser) {
        _browser->GetHost()->StopFinding(false);
    }
}

- (void)print {
    if (_browser) {
        _browser->GetHost()->Print();
    }
}

- (void)printToPDFWithCompletion:(void (^)(NSData *_Nullable))completion {
    if (!_browser) {
        completion(nil);
        return;
    }
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"arch-%@.pdf", NSUUID.UUID.UUIDString]];
    CefPdfPrintSettings settings;
    _browser->GetHost()->PrintToPDF(CefString(path.UTF8String), settings, new BridgePdfCallback(completion));
}

- (void)close {
    if (_browser) {
        _browser->GetHost()->CloseBrowser(true);
    }
}

@end
