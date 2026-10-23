// Initializes the Chromium Embedded Framework (CEF) and runs its message pump. Uses one `CefClient` per embedded browser.
#import "CEFBridge.h"

#include <crt_externs.h>
#include <dispatch/dispatch.h>
#include <map>

#include <atomic>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_cookie.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_values.h"
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
    // AppKit does not quit while a window shows a sheet with more than one button, and quits only once that sheet ends. Answer the sheets with Cancel first so that none holds the app open. Ending a sheet can show another one, so the loop repeats a bounded number of times.
    for (NSWindow *window in self.windows) {
        for (int attempt = 0; attempt < 32 && window.attachedSheet; attempt++) {
            [window endSheet:window.attachedSheet returnCode:NSModalResponseCancel];
        }
    }
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

// Called on the main thread only.
- (void)scheduleWork:(int64_t)delayMilliseconds {
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

    // CEF calls this from any thread, including the main thread from inside one of its own API calls such as `LoadURL`.
    // Running `CefDoMessageLoopWork()` there re-enters the message loop and hangs, so the work always waits for the next
    // pass of the main run loop, as the CEF client sample does.
    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        dispatch_async(dispatch_get_main_queue(), ^{ [[ARCHCEFPump shared] scheduleWork:delay_ms]; });
    }

    // Unsigned development builds lack a stable code identity. The login keychain would therefore prompt for the cookie
    // encryption key on every launch, blocking startup. The mock keychain avoids this until the app is signed.
    void OnBeforeCommandLineProcessing(const CefString &process_type, CefRefPtr<CefCommandLine> command_line) override {
        if (process_type.empty()) {
            command_line->AppendSwitch("use-mock-keychain");
            // Without it Chromium shows its own sign-in window and never asks GetAuthCredentials.
            command_line->AppendSwitch("disable-chrome-login-prompt");
        }
    }

private:
    IMPLEMENT_REFCOUNTING(BridgeApp);
};

bool gInitialized = false;

}  // namespace

#pragma mark - Runtime

@implementation ARCHCEFCookie
@end

namespace {

NSDate *ToNSDate(const cef_basetime_t &time) {
    cef_time_t exploded;
    double seconds = 0;
    if (!cef_time_from_basetime(time, &exploded) || !cef_time_to_doublet(&exploded, &seconds)) {
        return nil;
    }
    return [NSDate dateWithTimeIntervalSince1970:seconds];
}

cef_basetime_t ToBaseTime(NSDate *date) {
    cef_time_t exploded;
    cef_basetime_t time = {};
    if (cef_time_from_doublet(date.timeIntervalSince1970, &exploded)) {
        cef_time_to_basetime(&exploded, &time);
    }
    return time;
}

// Collects cookies as CEF visits them and reports the list when CEF releases the visitor, which also happens when the store has no cookies or cannot be read.
class CookieCollector : public CefCookieVisitor {
  public:
    explicit CookieCollector(void (^completion)(NSArray<ARCHCEFCookie *> *)) : completion_([completion copy]), cookies_([NSMutableArray array]) {}

    ~CookieCollector() override {
        NSArray<ARCHCEFCookie *> *cookies = [cookies_ copy];
        void (^completion)(NSArray<ARCHCEFCookie *> *) = completion_;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cookies); });
    }

    bool Visit(const CefCookie &cookie, int count, int total, bool &deleteCookie) override {
        ARCHCEFCookie *item = [[ARCHCEFCookie alloc] init];
        item.name = ToNSString(CefString(&cookie.name));
        item.value = ToNSString(CefString(&cookie.value));
        item.domain = ToNSString(CefString(&cookie.domain));
        item.path = ToNSString(CefString(&cookie.path));
        item.expires = cookie.has_expires ? ToNSDate(cookie.expires) : nil;
        item.secure = cookie.secure != 0;
        item.httpOnly = cookie.httponly != 0;
        [cookies_ addObject:item];
        return true;
    }

  private:
    void (^completion_)(NSArray<ARCHCEFCookie *> *);
    NSMutableArray<ARCHCEFCookie *> *cookies_;
    IMPLEMENT_REFCOUNTING(CookieCollector);
};

// Counts down the cookie writes of one batch and reports once the last finishes.
class CookieBatchCallback : public CefSetCookieCallback {
  public:
    CookieBatchCallback(int count, void (^completion)(void)) : remaining_(count), completion_([completion copy]) {}

    void OnComplete(bool success) override { Finish(); }

    void Finish() {
        if (--remaining_ == 0) {
            void (^completion)(void) = completion_;
            dispatch_async(dispatch_get_main_queue(), completion);
        }
    }

  private:
    std::atomic<int> remaining_;
    void (^completion_)(void);
    IMPLEMENT_REFCOUNTING(CookieBatchCallback);
};

CefCookie MakeCefCookie(ARCHCEFCookie *cookie) {
    CefCookie value;
    CefString(&value.name) = cookie.name.UTF8String;
    CefString(&value.value) = cookie.value.UTF8String;
    CefString(&value.domain) = cookie.domain.UTF8String;
    CefString(&value.path) = cookie.path.UTF8String;
    value.secure = cookie.secure;
    value.httponly = cookie.httpOnly;
    if (cookie.expires) {
        value.has_expires = true;
        value.expires = ToBaseTime(cookie.expires);
    }
    return value;
}

}  // namespace

@implementation ARCHCEFCookieStore

+ (void)visitAllCookies:(void (^)(NSArray<ARCHCEFCookie *> *))completion {
    CefRefPtr<CefCookieManager> manager = gInitialized ? CefCookieManager::GetGlobalManager(nullptr) : nullptr;
    CefRefPtr<CookieCollector> collector = new CookieCollector(completion);
    if (manager) {
        manager->VisitAllCookies(collector);
    }
}

+ (void)setCookie:(ARCHCEFCookie *)cookie forURL:(NSString *)url {
    CefRefPtr<CefCookieManager> manager = gInitialized ? CefCookieManager::GetGlobalManager(nullptr) : nullptr;
    if (!manager) {
        return;
    }
    manager->SetCookie(CefString(url.UTF8String), MakeCefCookie(cookie), nullptr);
}

+ (void)setCookies:(NSArray<ARCHCEFCookie *> *)cookies forURLs:(NSArray<NSString *> *)urls completion:(void (^)(void))completion {
    CefRefPtr<CefCookieManager> manager = gInitialized ? CefCookieManager::GetGlobalManager(nullptr) : nullptr;
    NSUInteger count = MIN(cookies.count, urls.count);
    if (!manager || count == 0) {
        dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    CefRefPtr<CookieBatchCallback> callback = new CookieBatchCallback((int)count, completion);
    for (NSUInteger index = 0; index < count; index++) {
        // A cookie CEF refuses never calls back, so it counts as finished at once.
        if (!manager->SetCookie(CefString(urls[index].UTF8String), MakeCefCookie(cookies[index]), callback)) {
            callback->Finish();
        }
    }
}

+ (void)deleteCookiesForURL:(NSString *)url name:(NSString *)name {
    CefRefPtr<CefCookieManager> manager = gInitialized ? CefCookieManager::GetGlobalManager(nullptr) : nullptr;
    if (manager) {
        manager->DeleteCookies(CefString(url.UTF8String), CefString(name.UTF8String), nullptr);
    }
}

@end

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
    // CEF shuts down only once AppKit has decided to quit, so a quit that does not happen leaves the engine running.
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationWillTerminateNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *notification) {
                                                      [ARCHCEFRuntime shutdown];
                                                  }];
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

#pragma mark - Download

@interface ARCHCEFDownload ()
@property (nonatomic, readwrite, copy, nullable) NSString *path;
@property (nonatomic, readwrite) int64_t receivedBytes;
@property (nonatomic, readwrite) int64_t totalBytes;
@property (nonatomic, readwrite) ARCHCEFDownloadState state;
- (instancetype)initWithIdentifier:(uint32_t)identifier url:(NSString *)url;
- (void)applyItem:(CefRefPtr<CefDownloadItem>)item callback:(CefRefPtr<CefDownloadItemCallback>)callback;
@end

@implementation ARCHCEFDownload {
    CefRefPtr<CefDownloadItemCallback> _callback;
    BOOL _pauseRequested;
    BOOL _cancelRequested;
}

- (instancetype)initWithIdentifier:(uint32_t)identifier url:(NSString *)url {
    self = [super init];
    if (!self) {
        return nil;
    }
    _identifier = identifier;
    _url = [url copy];
    _state = ARCHCEFDownloadStateInProgress;
    return self;
}

// The latest update's callback stays valid. Pause, resume, and cancel use it until the next update replaces it.
- (void)applyItem:(CefRefPtr<CefDownloadItem>)item callback:(CefRefPtr<CefDownloadItemCallback>)callback {
    _callback = callback;
    CefString fullPath = item->GetFullPath();
    self.path = fullPath.empty() ? nil : ToNSString(fullPath);
    self.receivedBytes = item->GetReceivedBytes();
    self.totalBytes = item->GetTotalBytes();
    if (item->IsComplete()) {
        self.state = ARCHCEFDownloadStateComplete;
    } else if (item->IsCanceled()) {
        self.state = ARCHCEFDownloadStateCanceled;
    } else if (item->IsInterrupted()) {
        self.state = ARCHCEFDownloadStateInterrupted;
    } else {
        self.state = ARCHCEFDownloadStateInProgress;
    }
    if (_cancelRequested) {
        _cancelRequested = NO;
        _pauseRequested = NO;
        callback->Cancel();
    } else if (_pauseRequested) {
        _pauseRequested = NO;
        callback->Pause();
    }
}

- (void)pause {
    if (_callback) {
        _callback->Pause();
    } else {
        _pauseRequested = YES;
    }
}

- (void)resume {
    _pauseRequested = NO;
    if (_callback) {
        _callback->Resume();
    }
}

- (void)cancel {
    if (_callback) {
        _callback->Cancel();
    } else {
        _cancelRequested = YES;
    }
}

@end

#pragma mark - Browser

@interface ARCHCEFBrowser ()
/// Set from a dismissed dialog until the navigation the user started finishes loading, so the page cannot hold that navigation with another dialog.
@property(nonatomic, readonly) BOOL suppressesDialogs;
- (void)handleAfterCreated:(CefRefPtr<CefBrowser>)browser;
- (void)handleDoClose;
- (void)handleDialog:(ARCHCEFDialogKind)kind message:(NSString *)message defaultText:(NSString *)defaultText completion:(void (^)(BOOL, NSString *_Nullable))completion;
- (void)handleLeavePageDialog:(void (^)(BOOL))completion;
- (void)handleResetDialogs;
- (void)handleTitle:(NSString *)title;
- (void)handleURL:(NSString *)url;
- (void)handleLoadingState:(BOOL)isLoading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)handleFaviconURLs:(NSArray<NSString *> *)urls;
- (void)handleFindResult:(int)count activeMatchOrdinal:(int)activeMatchOrdinal finalUpdate:(BOOL)finalUpdate;
- (void)handlePopup:(NSString *)url;
- (void)handleBeforeClose;
- (ARCHCEFDownload *)downloadForItem:(CefRefPtr<CefDownloadItem>)item;
- (void)handleBeforeDownload:(ARCHCEFDownload *)download
               suggestedName:(NSString *)suggestedName
                    decision:(void (^)(NSString *_Nullable, BOOL))decision;
- (void)handleDownloadUpdate:(ARCHCEFDownload *)download;
- (void)handlePermissionRequest:(ARCHCEFPermission)permissions origin:(NSString *)origin decision:(void (^)(BOOL))decision;
- (BOOL)handleShouldDownload:(NSString *)url hasDocument:(BOOL)hasDocument;
- (void)handleRenderProcessTerminated;
- (void)handleAuthenticationForHost:(NSString *)host
                               port:(int)port
                              realm:(NSString *)realm
                             scheme:(NSString *)scheme
                          originURL:(NSString *)originURL
                            isProxy:(BOOL)isProxy
                         completion:(void (^)(NSString *_Nullable, NSString *_Nullable))completion;
@end

namespace {

// Maps a media access request to bridge permissions. Returns `0` if no requested permission is recognized.
ARCHCEFPermission PermissionsFromMediaAccess(uint32_t requested) {
    ARCHCEFPermission permissions = 0;
    if (requested & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) {
        permissions |= ARCHCEFPermissionMicrophone;
    }
    if (requested & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) {
        permissions |= ARCHCEFPermissionCamera;
    }
    if (requested & (CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE)) {
        permissions |= ARCHCEFPermissionScreenCapture;
    }
    return permissions;
}

// Maps a permission prompt to bridge permissions. Returns `0` if any requested type is unsupported by the bridge.
ARCHCEFPermission PermissionsFromPrompt(uint32_t requested) {
    struct Mapping {
        uint32_t cefType;
        ARCHCEFPermission permission;
    };
    static const Mapping kMappings[] = {
        {CEF_PERMISSION_TYPE_CAMERA_STREAM, ARCHCEFPermissionCamera},
        {CEF_PERMISSION_TYPE_MIC_STREAM, ARCHCEFPermissionMicrophone},
        {CEF_PERMISSION_TYPE_GEOLOCATION, ARCHCEFPermissionGeolocation},
        {CEF_PERMISSION_TYPE_NOTIFICATIONS, ARCHCEFPermissionNotifications},
        {CEF_PERMISSION_TYPE_CLIPBOARD, ARCHCEFPermissionClipboard},
        {CEF_PERMISSION_TYPE_MIDI_SYSEX, ARCHCEFPermissionMidi},
    };
    ARCHCEFPermission permissions = 0;
    uint32_t remaining = requested;
    for (const Mapping &mapping : kMappings) {
        if (requested & mapping.cefType) {
            permissions |= mapping.permission;
            remaining &= ~mapping.cefType;
        }
    }
    return remaining == 0 ? permissions : 0;
}

// Forwards one browser's CEF callbacks to its `ARCHCEFBrowser`. The owner calls `Detach()` before releasing the client.
class BridgeClient : public CefClient,
                     public CefDisplayHandler,
                     public CefLifeSpanHandler,
                     public CefLoadHandler,
                     public CefFindHandler,
                     public CefDownloadHandler,
                     public CefJSDialogHandler,
                     public CefPermissionHandler,
                     public CefRequestHandler {
public:
    explicit BridgeClient(ARCHCEFBrowser *owner) : owner_(owner) {}

    void Detach() { owner_ = nil; }

    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }

    // The app shows the page's dialogs as its own sheets and answers through the callback, which stays alive in the block until then.
    bool OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString &origin_url, JSDialogType dialog_type, const CefString &message_text,
                    const CefString &default_prompt_text, CefRefPtr<CefJSDialogCallback> callback, bool &suppress_message) override {
        if (!owner_) {
            return false;
        }
        if (owner_.suppressesDialogs) {
            suppress_message = true;
            return false;
        }
        ARCHCEFDialogKind kind = dialog_type == JSDIALOGTYPE_CONFIRM ? ARCHCEFDialogKindConfirm
                                 : dialog_type == JSDIALOGTYPE_PROMPT ? ARCHCEFDialogKindPrompt
                                                                      : ARCHCEFDialogKindAlert;
        CefRefPtr<CefJSDialogCallback> continuation = callback;
        [owner_ handleDialog:kind message:ToNSString(message_text) defaultText:ToNSString(default_prompt_text) completion:^(BOOL accepted, NSString *text) {
            continuation->Continue(accepted, CefString(text ? text.UTF8String : ""));
        }];
        return true;
    }

    bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser, const CefString &message_text, bool is_reload,
                              CefRefPtr<CefJSDialogCallback> callback) override {
        if (!owner_) {
            return false;
        }
        CefRefPtr<CefJSDialogCallback> continuation = callback;
        [owner_ handleLeavePageDialog:^(BOOL leave) { continuation->Continue(leave, CefString()); }];
        return true;
    }

    void OnResetDialogState(CefRefPtr<CefBrowser> browser) override { [owner_ handleResetDialogs]; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

    bool CanDownload(CefRefPtr<CefBrowser> browser, const CefString &url, const CefString &request_method) override {
        return owner_ != nil && owner_.allowsDownloads && [owner_ handleShouldDownload:ToNSString(url) hasDocument:browser->HasDocument()];
    }

    bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item, const CefString &suggested_name,
                          CefRefPtr<CefBeforeDownloadCallback> callback) override {
        if (!owner_) {
            return false;
        }
        CefRefPtr<CefBeforeDownloadCallback> continuation = callback;
        [owner_ handleBeforeDownload:[owner_ downloadForItem:download_item]
                       suggestedName:ToNSString(suggested_name)
                            decision:^(NSString *_Nullable path, BOOL showDialog) {
                                continuation->Continue(CefString(path ? path.UTF8String : ""), showDialog);
                            }];
        return true;
    }

    void OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
                           CefRefPtr<CefDownloadItemCallback> callback) override {
        ARCHCEFDownload *download = [owner_ downloadForItem:download_item];
        [download applyItem:download_item callback:callback];
        [owner_ handleDownloadUpdate:download];
    }

    bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &requesting_origin,
                                        uint32_t requested_permissions, CefRefPtr<CefMediaAccessCallback> callback) override {
        ARCHCEFPermission permissions = PermissionsFromMediaAccess(requested_permissions);
        if (!owner_ || permissions == 0) {
            return false;
        }
        CefRefPtr<CefMediaAccessCallback> decision = callback;
        [owner_ handlePermissionRequest:permissions
                                 origin:ToNSString(requesting_origin)
                               decision:^(BOOL allow) {
                                   decision->Continue(allow ? requested_permissions : static_cast<uint32_t>(CEF_MEDIA_PERMISSION_NONE));
                               }];
        return true;
    }

    // Returning `false` lets CEF handle the request; CEF ignores it in Alloy style.
    bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id, const CefString &requesting_origin,
                                uint32_t requested_permissions, CefRefPtr<CefPermissionPromptCallback> callback) override {
        ARCHCEFPermission permissions = PermissionsFromPrompt(requested_permissions);
        if (!owner_ || permissions == 0) {
            return false;
        }
        CefRefPtr<CefPermissionPromptCallback> decision = callback;
        [owner_ handlePermissionRequest:permissions
                                 origin:ToNSString(requesting_origin)
                               decision:^(BOOL allow) {
                                   decision->Continue(allow ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
                               }];
        return true;
    }

    void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status, int error_code,
                                   const CefString &error_string) override {
        [owner_ handleRenderProcessTerminated];
    }

    // CEF asks on the IO thread. The app asks with its own sheet on the main thread and answers through the callback, which stays alive in the block until then.
    bool GetAuthCredentials(CefRefPtr<CefBrowser> browser, const CefString &origin_url, bool isProxy, const CefString &host, int port,
                            const CefString &realm, const CefString &scheme, CefRefPtr<CefAuthCallback> callback) override {
        CefRefPtr<BridgeClient> client = this;
        CefRefPtr<CefAuthCallback> continuation = callback;
        NSString *hostName = ToNSString(host);
        NSString *realmName = ToNSString(realm);
        NSString *schemeName = ToNSString(scheme).lowercaseString;
        NSString *origin = ToNSString(origin_url);
        dispatch_async(dispatch_get_main_queue(), ^{
            ARCHCEFBrowser *owner = client->owner_;
            if (!owner) {
                continuation->Cancel();
                return;
            }
            [owner handleAuthenticationForHost:hostName
                                          port:port
                                         realm:realmName
                                        scheme:schemeName
                                     originURL:origin
                                       isProxy:isProxy
                                    completion:^(NSString *user, NSString *password) {
                                        if (user) {
                                            continuation->Continue(CefString(user.UTF8String), CefString(password ? password.UTF8String : ""));
                                        } else {
                                            continuation->Cancel();
                                        }
                                    }];
        });
        return true;
    }

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

    // Returning false would make CEF close the window that holds the browser's view, which is the app's window. The view leaves its parent instead, and CEF finishes closing the browser once the view is released.
    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        if (!owner_) {
            return false;
        }
        [owner_ handleDoClose];
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

// Resolves screenshot requests by the message id that `ExecuteDevToolsMethod` assigned.
class BridgeDevToolsObserver : public CefDevToolsMessageObserver {
public:
    void Expect(int messageID, void (^completion)(NSData *_Nullable)) { pending_[messageID] = completion; }

    void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success, const void *result,
                                size_t result_size) override {
        auto pending = pending_.find(message_id);
        if (pending == pending_.end()) {
            return;
        }
        void (^completion)(NSData *_Nullable) = pending->second;
        pending_.erase(pending);
        NSData *png = nil;
        if (success && result_size > 0) {
            NSData *json = [NSData dataWithBytesNoCopy:const_cast<void *>(result) length:result_size freeWhenDone:NO];
            id base64 = [[NSJSONSerialization JSONObjectWithData:json options:0 error:nil] objectForKey:@"data"];
            if ([base64 isKindOfClass:NSString.class]) {
                png = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
            }
        }
        completion(png);
    }

private:
    std::map<int, void (^)(NSData *_Nullable)> pending_;
    IMPLEMENT_REFCOUNTING(BridgeDevToolsObserver);
};

}  // namespace

@implementation ARCHCEFBrowser {
    CefRefPtr<BridgeClient> _client;
    CefRefPtr<CefBrowser> _browser;
    CefRefPtr<BridgeDevToolsObserver> _devToolsObserver;
    CefRefPtr<CefRegistration> _devToolsRegistration;
    __weak id<ARCHCEFBrowserDelegate> _delegate;
    NSView *_parentView;
    NSMutableDictionary<NSNumber *, ARCHCEFDownload *> *_downloads;
    /// Set while `tryCloseWithCompletion:` waits for the page's `beforeunload` handlers.
    void (^_pendingClose)(BOOL);
    /// Set while the page waits for the answer to an `alert`, `confirm`, or `prompt` dialog.
    void (^_pendingDialog)(BOOL, NSString *_Nullable);
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
    _allowsDownloads = YES;
    _downloads = [NSMutableDictionary dictionary];
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
    // CEF resets the dialog state as soon as the navigation starts, before the page runs again, so only the end of loading ends the suppression.
    if (!isLoading) {
        _suppressesDialogs = NO;
    }
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

- (void)handleDoClose {
    [_browserView removeFromSuperview];
    _browserView = nil;
    [self finishPendingClose:YES];
}

- (void)finishPendingClose:(BOOL)closing {
    void (^completion)(BOOL) = _pendingClose;
    _pendingClose = nil;
    if (completion) {
        completion(closing);
    }
}

- (void)handleDialog:(ARCHCEFDialogKind)kind message:(NSString *)message defaultText:(NSString *)defaultText completion:(void (^)(BOOL, NSString *_Nullable))completion {
    id<ARCHCEFBrowserDelegate> delegate = _delegate;
    if (!delegate) {
        completion(kind == ARCHCEFDialogKindAlert, nil);
        return;
    }
    // The dialog is answered once, by the sheet or by a navigation the user starts, whichever comes first.
    __weak ARCHCEFBrowser *weakSelf = self;
    __block BOOL answered = NO;
    void (^answer)(BOOL, NSString *_Nullable) = ^(BOOL accepted, NSString *_Nullable text) {
        if (answered) {
            return;
        }
        answered = YES;
        ARCHCEFBrowser *strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf->_pendingDialog = nil;
        }
        completion(accepted, text);
    };
    _pendingDialog = answer;
    [delegate cefBrowserRunDialog:kind message:message defaultText:defaultText completion:answer];
}

// The page stops while its dialog waits, so a navigation the user starts would never commit. Dismiss the dialog first, as other browsers do on reload or going back.
- (void)dismissPendingDialog {
    void (^answer)(BOOL, NSString *_Nullable) = _pendingDialog;
    if (!answer) {
        return;
    }
    _suppressesDialogs = YES;
    answer(NO, nil);
    [_delegate cefBrowserDidResetDialogs];
}

- (void)handleLeavePageDialog:(void (^)(BOOL))completion {
    id<ARCHCEFBrowserDelegate> delegate = _delegate;
    __weak ARCHCEFBrowser *weakSelf = self;
    void (^finish)(BOOL) = ^(BOOL leave) {
        // Staying cancels a close that was waiting on this answer.
        if (!leave) {
            [weakSelf finishPendingClose:NO];
        }
        completion(leave);
    };
    if (delegate) {
        [delegate cefBrowserRunLeavePageDialogWithCompletion:finish];
    } else {
        finish(YES);
    }
}

- (void)handleResetDialogs {
    [_delegate cefBrowserDidResetDialogs];
}

- (void)handleBeforeClose {
    _browser = nullptr;
    _browserView = nil;
    // `+shutdown` clears `gInitialized` before it closes every browser at quit. Those closes are not reported, so the session keeps the tabs and saves them.
    if (gInitialized) {
        [_delegate cefBrowserDidClose];
    }
}

// Downloads are keyed by their CEF identifiers and retained for the browser's lifetime so interrupted downloads can still be resumed.
- (ARCHCEFDownload *)downloadForItem:(CefRefPtr<CefDownloadItem>)item {
    NSNumber *key = @(item->GetId());
    ARCHCEFDownload *download = _downloads[key];
    if (!download) {
        download = [[ARCHCEFDownload alloc] initWithIdentifier:item->GetId() url:ToNSString(item->GetURL())];
        _downloads[key] = download;
    }
    return download;
}

- (BOOL)hasDownloadsInProgress {
    for (ARCHCEFDownload *download in _downloads.allValues) {
        if (download.state == ARCHCEFDownloadStateInProgress) {
            return YES;
        }
    }
    return NO;
}

- (void)handleBeforeDownload:(ARCHCEFDownload *)download
               suggestedName:(NSString *)suggestedName
                    decision:(void (^)(NSString *_Nullable, BOOL))decision {
    id<ARCHCEFBrowserDelegate> delegate = _delegate;
    if (delegate) {
        [delegate cefBrowserDidStartDownload:download suggestedName:suggestedName decision:decision];
    } else {
        decision(nil, YES);
    }
}

- (void)handleDownloadUpdate:(ARCHCEFDownload *)download {
    [_delegate cefBrowserDidUpdateDownload:download];
}

- (BOOL)handleShouldDownload:(NSString *)url hasDocument:(BOOL)hasDocument {
    id<ARCHCEFBrowserDelegate> delegate = _delegate;
    return delegate == nil || [delegate cefBrowserShouldDownloadURL:url hasDocument:hasDocument];
}

- (void)handlePermissionRequest:(ARCHCEFPermission)permissions origin:(NSString *)origin decision:(void (^)(BOOL))decision {
    id<ARCHCEFBrowserDelegate> delegate = _delegate;
    if (delegate) {
        [delegate cefBrowserDidRequestPermissions:permissions fromOrigin:origin decision:decision];
    } else {
        decision(NO);
    }
}

- (void)handleRenderProcessTerminated {
    [_delegate cefBrowserRenderProcessDidTerminate];
}

- (void)handleAuthenticationForHost:(NSString *)host
                               port:(int)port
                              realm:(NSString *)realm
                             scheme:(NSString *)scheme
                          originURL:(NSString *)originURL
                            isProxy:(BOOL)isProxy
                         completion:(void (^)(NSString *_Nullable, NSString *_Nullable))completion {
    id<ARCHCEFBrowserDelegate> delegate = _delegate;
    if (delegate) {
        [delegate cefBrowserDidReceiveAuthenticationChallengeForHost:host port:port realm:realm scheme:scheme originURL:originURL isProxy:isProxy completion:completion];
    } else {
        completion(nil, nil);
    }
}

- (void)loadURL:(NSString *)url {
    [self dismissPendingDialog];
    if (_browser) {
        _browser->GetMainFrame()->LoadURL(CefString(url.UTF8String));
    }
}

- (void)reload {
    [self dismissPendingDialog];
    if (_browser) {
        _browser->Reload();
    }
}

- (void)reloadIgnoringCache {
    [self dismissPendingDialog];
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
    [self dismissPendingDialog];
    if (_browser) {
        _browser->GoBack();
    }
}

- (void)goForward {
    [self dismissPendingDialog];
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

- (void)captureScreenshotBeyondViewport:(BOOL)beyondViewport completion:(void (^)(NSData *_Nullable))completion {
    if (!_browser) {
        completion(nil);
        return;
    }
    CefRefPtr<CefBrowserHost> host = _browser->GetHost();
    if (!_devToolsObserver) {
        _devToolsObserver = new BridgeDevToolsObserver;
        _devToolsRegistration = host->AddDevToolsMessageObserver(_devToolsObserver);
    }
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("format", "png");
    params->SetBool("captureBeyondViewport", beyondViewport);
    int messageID = host->ExecuteDevToolsMethod(0, "Page.captureScreenshot", params);
    if (messageID == 0) {
        completion(nil);
        return;
    }
    _devToolsObserver->Expect(messageID, completion);
}

- (void)close {
    if (_browser) {
        _browser->GetHost()->CloseBrowser(true);
    }
}

- (void)tryCloseWithCompletion:(void (^)(BOOL))completion {
    if (!_browser) {
        completion(YES);
        return;
    }
    _pendingClose = [completion copy];
    _browser->GetHost()->CloseBrowser(false);
}

@end
