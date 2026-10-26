// Chromium profiles: the cookies, site storage, and permission answers of each request context.
#import "CEFBridgeInternal.h"

#include <dispatch/dispatch.h>

#include <atomic>

#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_cookie.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_values.h"

using namespace cef_bridge;

#pragma mark - Cookies

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

ARCHCEFCookieSameSite ToBridgeSameSite(cef_cookie_same_site_t sameSite) {
    switch (sameSite) {
        case CEF_COOKIE_SAME_SITE_NO_RESTRICTION: return ARCHCEFCookieSameSiteNoRestriction;
        case CEF_COOKIE_SAME_SITE_LAX_MODE: return ARCHCEFCookieSameSiteLax;
        case CEF_COOKIE_SAME_SITE_STRICT_MODE: return ARCHCEFCookieSameSiteStrict;
        default: return ARCHCEFCookieSameSiteUnspecified;
    }
}

cef_cookie_same_site_t ToCefSameSite(ARCHCEFCookieSameSite sameSite) {
    switch (sameSite) {
        case ARCHCEFCookieSameSiteNoRestriction: return CEF_COOKIE_SAME_SITE_NO_RESTRICTION;
        case ARCHCEFCookieSameSiteLax: return CEF_COOKIE_SAME_SITE_LAX_MODE;
        case ARCHCEFCookieSameSiteStrict: return CEF_COOKIE_SAME_SITE_STRICT_MODE;
        case ARCHCEFCookieSameSiteUnspecified: return CEF_COOKIE_SAME_SITE_UNSPECIFIED;
    }
    return CEF_COOKIE_SAME_SITE_UNSPECIFIED;
}

ARCHCEFCookie *MakeBridgeCookie(const CefCookie &cookie) {
    ARCHCEFCookie *item = [[ARCHCEFCookie alloc] init];
    item.name = ToNSString(CefString(&cookie.name));
    item.value = ToNSString(CefString(&cookie.value));
    item.domain = ToNSString(CefString(&cookie.domain));
    item.path = ToNSString(CefString(&cookie.path));
    item.expires = cookie.has_expires ? ToNSDate(cookie.expires) : nil;
    item.secure = cookie.secure != 0;
    item.httpOnly = cookie.httponly != 0;
    item.sameSite = ToBridgeSameSite(cookie.same_site);
    return item;
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
        [cookies_ addObject:MakeBridgeCookie(cookie)];
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
    value.same_site = ToCefSameSite(cookie.sameSite);
    if (cookie.expires) {
        value.has_expires = true;
        value.expires = ToBaseTime(cookie.expires);
    }
    return value;
}

}  // namespace

#pragma mark - Site data

namespace {

// Reports once CEF releases it: after the flush it was given finishes, or at once when the flush cannot start.
class CookieFlushCallback : public CefCompletionCallback {
  public:
    explicit CookieFlushCallback(void (^completion)(void)) : completion_([completion copy]) {}

    ~CookieFlushCallback() override { dispatch_async(dispatch_get_main_queue(), completion_); }

    void OnComplete() override {}

  private:
    void (^completion_)(void);
    IMPLEMENT_REFCOUNTING(CookieFlushCallback);
};

// Deletes the cookies a test accepts as CEF visits them, and reports once CEF releases the visitor, which also happens when the store has no cookies or cannot be read.
class CookieDeleter : public CefCookieVisitor {
  public:
    CookieDeleter(BOOL (^test)(ARCHCEFCookie *), void (^completion)(void)) : test_([test copy]), completion_([completion copy]) {}

    // CEF releases the visitor inside its own call, so the report waits for the next turn of the main run loop.
    ~CookieDeleter() override { dispatch_async(dispatch_get_main_queue(), completion_); }

    bool Visit(const CefCookie &cookie, int count, int total, bool &deleteCookie) override {
        deleteCookie = test_(MakeBridgeCookie(cookie));
        return true;
    }

  private:
    BOOL (^test_)(ARCHCEFCookie *);
    void (^completion_)(void);
    IMPLEMENT_REFCOUNTING(CookieDeleter);
};

// The storage types of `Storage.clearDataForOrigin` that belong to an origin, leaving out cookies, which the cookie store deletes, and the shader cache, which Chromium clears for every site at once. Chromium ignores names it does not know.
const char kClearedStorageTypes[] =
    "file_systems,indexeddb,local_storage,websql,service_workers,cache_storage,interest_groups,shared_storage,storage_buckets";

// Runs `Storage.clearDataForOrigin` for each origin in a hidden browser of its own, then closes that browser. A DevTools client stays attached to a browser until the browser closes, and an attached client keeps Chromium from timing out a hung page, so no tab makes the calls. The browser counts in `gUnshownBrowsers`, so that a quit meanwhile waits for the answers and the close.
class StorageClearingClient : public CefClient, public CefLifeSpanHandler, public CefDevToolsMessageObserver {
  public:
    StorageClearingClient(NSArray<NSString *> *origins, NSView *parentView, void (^completion)(void))
        : origins_([origins copy]), parentView_(parentView), completion_([completion copy]) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        gUnshownBrowsers++;
        browser_ = browser;
        CefRefPtr<CefBrowserHost> host = browser->GetHost();
        registration_ = host->AddDevToolsMessageObserver(this);
        // A call that fails can answer before `ExecuteDevToolsMethod` returns, so the answers count only once every call is sent.
        isSending_ = YES;
        for (NSString *origin in origins_) {
            CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
            params->SetString("origin", origin.UTF8String);
            params->SetString("storageTypes", kClearedStorageTypes);
            int messageID = host->ExecuteDevToolsMethod(0, "Storage.clearDataForOrigin", params);
            if (messageID != 0) {
                [sent_ addObject:@(messageID)];
            }
        }
        isSending_ = NO;
        FinishIfAnswered();
    }

    void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success, const void *result, size_t result_size) override {
        [answered_ addObject:@(message_id)];
        FinishIfAnswered();
    }

    // Answers still pending when the agent detaches never arrive.
    void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) override { Finish(); }

    // The parent view is in no window. Returning false would ask CEF to close that window; the browser's view leaves its parent instead, and CEF finishes closing the browser once the view is released.
    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        [CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle()) removeFromSuperview];
        return true;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        gUnshownBrowsers--;
        Finish();
        browser_ = nullptr;
        parentView_ = nil;
    }

  private:
    void FinishIfAnswered() {
        if (!isSending_ && [sent_ isSubsetOfSet:answered_]) {
            Finish();
        }
    }

    // Reports once and closes the browser. It runs on the next turn of the main run loop, outside CEF's callback.
    void Finish() {
        if (isFinished_) {
            return;
        }
        isFinished_ = YES;
        CefRefPtr<StorageClearingClient> client = this;
        dispatch_async(dispatch_get_main_queue(), ^{
            client->registration_ = nullptr;
            if (client->browser_) {
                client->browser_->GetHost()->CloseBrowser(true);
            }
            client->completion_();
        });
    }

    NSArray<NSString *> *origins_;
    NSView *parentView_;
    void (^completion_)(void);
    CefRefPtr<CefBrowser> browser_;
    CefRefPtr<CefRegistration> registration_;
    NSMutableSet<NSNumber *> *sent_ = [NSMutableSet set];
    NSMutableSet<NSNumber *> *answered_ = [NSMutableSet set];
    BOOL isSending_ = NO;
    BOOL isFinished_ = NO;
    IMPLEMENT_REFCOUNTING(StorageClearingClient);
};

}  // namespace

#pragma mark - Request context

@interface ARCHCEFRequestContext ()
/// Creates the object before CEF has a context for it.
- (instancetype)initWithoutContext;
/// Runs the calls that waited for Chromium to initialize the context, in order. Later calls run at once.
- (void)runWaitingCalls;
@end

namespace {

// Tells its context object on the main queue once Chromium has initialized both the context and its cookie store. CEF keeps the handler until every object of the context is gone.
class ContextReadiness : public CefRequestContextHandler, public CefCompletionCallback {
  public:
    explicit ContextReadiness(ARCHCEFRequestContext *owner) : owner_(owner) {}

    void OnRequestContextInitialized(CefRefPtr<CefRequestContext> request_context) override { Arrive(); }

    // The cookie manager calls it once its storage has initialized.
    void OnComplete() override { Arrive(); }

  private:
    void Arrive() {
        if (--remaining_ == 0) {
            __weak ARCHCEFRequestContext *owner = owner_;
            dispatch_async(dispatch_get_main_queue(), ^{ [owner runWaitingCalls]; });
        }
    }

    __weak ARCHCEFRequestContext *owner_;
    std::atomic<int> remaining_{2};
    IMPLEMENT_REFCOUNTING(ContextReadiness);
};

}  // namespace

@implementation ARCHCEFRequestContext {
    CefRefPtr<CefRequestContext> _context;
    CefRefPtr<CefCookieManager> _cookieManager;
    /// The calls made before Chromium reported the context and its cookie store initialized, oldest first. Nil once calls run at once.
    NSMutableArray<dispatch_block_t> *_waitingCalls;
}

+ (ARCHCEFRequestContext *)globalContext {
    static ARCHCEFRequestContext *globalContext;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ globalContext = [[ARCHCEFRequestContext alloc] initWithoutContext]; });
    return globalContext;
}

- (instancetype)initWithoutContext {
    self = [super init];
    if (self) {
        [gRequestContexts addObject:self];
    }
    return self;
}

- (instancetype)initWithCachePath:(NSString *)cachePath {
    if (!gInitialized || ![cachePath.stringByStandardizingPath.stringByDeletingLastPathComponent isEqualToString:gRootCachePath]) {
        return nil;
    }
    self = [self initWithoutContext];
    if (!self) {
        return nil;
    }
    _waitingCalls = [NSMutableArray array];
    // The other settings stay empty, as the runtime leaves its own.
    CefRequestContextSettings settings;
    CefString(&settings.cache_path) = cachePath.UTF8String;
    CefRefPtr<ContextReadiness> readiness = new ContextReadiness(self);
    _context = CefRequestContext::CreateContext(settings, readiness);
    if (!_context) {
        return nil;
    }
    _cookieManager = _context->GetCookieManager(readiness);
    return self;
}

- (void)attachContext:(CefRefPtr<CefRequestContext>)context {
    _context = context;
    _cookieManager = context ? context->GetCookieManager(nullptr) : nullptr;
}

- (void)detachContext {
    _cookieManager = nullptr;
    _context = nullptr;
    [self runWaitingCalls];
    [self detachExtensions];
}

- (void)runWaitingCalls {
    NSArray<dispatch_block_t> *calls = _waitingCalls;
    _waitingCalls = nil;
    for (dispatch_block_t call in calls) {
        call();
    }
}

- (void)whenReady:(dispatch_block_t)call {
    if (_waitingCalls) {
        [_waitingCalls addObject:[call copy]];
    } else {
        call();
    }
}

- (CefRefPtr<CefRequestContext>)cefContext {
    return _context;
}

- (void)visitAllCookies:(void (^)(NSArray<ARCHCEFCookie *> *))completion {
    [self whenReady:^{
        CefRefPtr<CookieCollector> collector = new CookieCollector(completion);
        if (self->_cookieManager) {
            self->_cookieManager->VisitAllCookies(collector);
        }
    }];
}

- (void)setCookies:(NSArray<ARCHCEFCookie *> *)cookies forURLs:(NSArray<NSString *> *)urls completion:(void (^)(void))completion {
    [self whenReady:^{
        NSUInteger count = MIN(cookies.count, urls.count);
        if (!self->_cookieManager || count == 0) {
            dispatch_async(dispatch_get_main_queue(), completion);
            return;
        }
        CefRefPtr<CookieBatchCallback> callback = new CookieBatchCallback((int)count, completion);
        for (NSUInteger index = 0; index < count; index++) {
            // A cookie CEF refuses never calls back, so it counts as finished at once.
            if (!self->_cookieManager->SetCookie(CefString(urls[index].UTF8String), MakeCefCookie(cookies[index]), callback)) {
                callback->Finish();
            }
        }
    }];
}

/// Writes the cookie store to disk, then calls `completion` once on the main thread.
- (void)flushCookiesWithCompletion:(void (^)(void))completion {
    CefRefPtr<CookieFlushCallback> callback = new CookieFlushCallback(completion);
    if (_cookieManager) {
        _cookieManager->FlushStore(callback);
    }
}

- (void)deleteCookiesPassingTest:(BOOL (^)(ARCHCEFCookie *))test completion:(void (^)(void))completion {
    [self whenReady:^{
        // The flush of the store the deleter visited runs after the deletions, so its end reports them applied.
        CefRefPtr<CookieDeleter> deleter = new CookieDeleter(test, ^{ [self flushCookiesWithCompletion:completion]; });
        if (self->_cookieManager) {
            self->_cookieManager->VisitAllCookies(deleter);
        }
    }];
}

- (void)clearStorageForOrigins:(NSArray<NSString *> *)origins completion:(void (^)(void))completion {
    [self whenReady:^{
        if (!self->_context || origins.count == 0) {
            dispatch_async(dispatch_get_main_queue(), completion);
            return;
        }
        // The browser needs a parent view, which stays out of every window and holds the browser's view until it closes.
        NSView *parentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)];
        CefRefPtr<StorageClearingClient> client = new StorageClearingClient(origins, parentView, completion);
        CefWindowInfo windowInfo;
        windowInfo.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(parentView), CefRect(0, 0, 1, 1));
        windowInfo.hidden = true;
        CefBrowserSettings settings;
        if (!CefBrowserHost::CreateBrowser(windowInfo, client, CefString("about:blank"), settings, nullptr, self->_context)) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
    }];
}

- (void)setPermissionSetting:(ARCHCEFPermissionSetting)setting forPermissions:(ARCHCEFPermission)permissions origin:(NSString *)origin {
    [self whenReady:^{
        if (!self->_context) {
            return;
        }
        // The content settings in which the profile keeps each answer that the prompt (see `PermissionsFromPrompt`) gives.
        struct Mapping {
            ARCHCEFPermission permission;
            cef_content_setting_types_t type;
        };
        static const Mapping kMappings[] = {
            {ARCHCEFPermissionCamera, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA},
            {ARCHCEFPermissionMicrophone, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC},
            {ARCHCEFPermissionGeolocation, CEF_CONTENT_SETTING_TYPE_GEOLOCATION},
            {ARCHCEFPermissionNotifications, CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS},
            {ARCHCEFPermissionClipboard, CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE},
            {ARCHCEFPermissionMidi, CEF_CONTENT_SETTING_TYPE_MIDI_SYSEX},
        };
        cef_content_setting_values_t value = CEF_CONTENT_SETTING_VALUE_DEFAULT;
        if (setting == ARCHCEFPermissionSettingAllow) {
            value = CEF_CONTENT_SETTING_VALUE_ALLOW;
        } else if (setting == ARCHCEFPermissionSettingBlock) {
            value = CEF_CONTENT_SETTING_VALUE_BLOCK;
        }
        CefString url(origin.UTF8String);
        for (const Mapping &mapping : kMappings) {
            if (permissions & mapping.permission) {
                self->_context->SetContentSetting(url, url, mapping.type, value);
            }
        }
    }];
}

@end
