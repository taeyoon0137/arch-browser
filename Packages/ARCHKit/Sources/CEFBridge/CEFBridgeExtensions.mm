// Chromium-format extensions through the extension runtime of Arch's engine: each request context's runtime and the handler that passes its requests to the app, the windows and tabs that extensions see, and actions and their popups.
#import "CEFBridgeInternal.h"

#include <dispatch/dispatch.h>

#include <algorithm>
#include <vector>

#include "include/cef_browser.h"
#include "include/cef_extension_runtime.h"
#include "include/cef_values.h"

using namespace cef_bridge;

@interface ARCHCEFExtension ()
- (instancetype)initWithDictionary:(CefRefPtr<CefDictionaryValue>)dictionary;
@end

@implementation ARCHCEFExtension

- (instancetype)initWithDictionary:(CefRefPtr<CefDictionaryValue>)dictionary {
    self = [super init];
    if (self) {
        _identifier = ToNSString(dictionary->GetString("id"));
        _name = ToNSString(dictionary->GetString("name"));
        _version = ToNSString(dictionary->GetString("version"));
        _path = ToNSString(dictionary->GetString("path"));
        _isEnabled = dictionary->GetBool("enabled");
    }
    return self;
}

@end

@interface ARCHCEFExtensionAction ()
- (instancetype)initWithDictionary:(CefRefPtr<CefDictionaryValue>)dictionary scale:(CGFloat)scale;
@end

@implementation ARCHCEFExtensionAction

- (instancetype)initWithDictionary:(CefRefPtr<CefDictionaryValue>)dictionary scale:(CGFloat)scale {
    self = [super init];
    if (self) {
        _extensionIdentifier = ToNSString(dictionary->GetString("id"));
        _title = ToNSString(dictionary->GetString("title"));
        _badgeText = ToNSString(dictionary->GetString("badgeText"));
        _isEnabled = dictionary->GetBool("enabled");
        _wantsSiteAccess = dictionary->GetBool("wantsSiteAccess");
        CefRefPtr<CefBinaryValue> png = dictionary->HasKey("icon") ? dictionary->GetBinary("icon") : nullptr;
        if (png && png->GetSize() > 0) {
            NSMutableData *data = [NSMutableData dataWithLength:png->GetSize()];
            png->GetData(data.mutableBytes, data.length, 0);
            NSImage *icon = [[NSImage alloc] initWithData:data];
            NSImageRep *pixels = icon.representations.firstObject;
            // CEF draws the icon at the requested scale; in points it is that much smaller.
            if (icon && pixels && scale > 0) {
                icon.size = NSMakeSize(pixels.pixelsWide / scale, pixels.pixelsHigh / scale);
            }
            _icon = icon;
        }
    }
    return self;
}

@end

@interface ARCHCEFExtensionWindow ()
- (instancetype)initWithContentView:(NSView *)contentView;
/// Creates CEF's window over the content view's window with the runtime, then applies the tabs and focus it was given meanwhile. Without a runtime, or once closed, the window stays without one.
- (void)attachRuntime:(CefRefPtr<CefExtensionRuntime>)runtime;
/// CEF's window, or null before the runtime created it and once closed.
- (CefRefPtr<CefExtensionWindow>)cefWindow;
/// Whether the last tabs CEF received list the browser.
- (BOOL)listsBrowser:(ARCHCEFBrowser *)browser;
/// Sends the tabs again if they list the browser, which CEF has just created.
- (void)browserDidCreate:(ARCHCEFBrowser *)browser;
/// Gives up waiting for the tabs when the browser, which CEF is closing, is one of them.
- (void)browserWillClose:(ARCHCEFBrowser *)browser;
/// Runs `block` once with YES when CEF's window exists and the tabs it last received are every tab the app listed, each created, as an answer to `OnOpenWindow` needs, or with NO once that cannot happen: the window has no CEF window, it closed, or one of its tabs closed first.
- (void)whenTabsListed:(void (^)(BOOL listed))block;
@end

@interface ARCHCEFExtensionPopup ()
- (instancetype)initWithPopup:(CefRefPtr<CefExtensionPopup>)popup;
- (void)handleSizeChange:(NSSize)size;
- (void)handleClose;
@end

namespace {

// Every extension window that has not closed, so that a browser that CEF creates later joins the windows that list it.
NSHashTable<ARCHCEFExtensionWindow *> *gExtensionWindows = [NSHashTable weakObjectsHashTable];

// An answer to `OnOpenTab` that waits until a window lists the new tab, as CEF asks, or the tab goes.
struct PendingTab {
    CefRefPtr<CefExtensionTabCallback> callback;
    __weak ARCHCEFBrowser *browser;
};
std::vector<PendingTab> gPendingTabs;

// Answers each pending tab that a window lists now with its browser, and each that went with null.
void ResolvePendingTabs() {
    std::vector<PendingTab> waiting;
    std::vector<PendingTab> answered;
    for (PendingTab &pending : gPendingTabs) {
        ARCHCEFBrowser *browser = pending.browser;
        BOOL listed = NO;
        for (ARCHCEFExtensionWindow *window in gExtensionWindows) {
            listed = listed || (browser && [window listsBrowser:browser]);
        }
        if (!browser || listed || !gInitialized) {
            answered.push_back(pending);
        } else {
            waiting.push_back(pending);
        }
    }
    gPendingTabs = waiting;
    // Continue may call back into the bridge, so the list is up to date first.
    for (PendingTab &pending : answered) {
        ARCHCEFBrowser *browser = pending.browser;
        pending.callback->Continue(browser ? [browser cefBrowser] : nullptr);
    }
}

// Answers the pending tabs of a browser that CEF is closing with null.
void CancelPendingTabs(ARCHCEFBrowser *browser) {
    std::vector<PendingTab> waiting;
    std::vector<PendingTab> cancelled;
    for (PendingTab &pending : gPendingTabs) {
        ARCHCEFBrowser *candidate = pending.browser;
        if (candidate == browser) {
            cancelled.push_back(pending);
        } else {
            waiting.push_back(pending);
        }
    }
    gPendingTabs = waiting;
    for (PendingTab &pending : cancelled) {
        pending.callback->Continue(nullptr);
    }
}

// The bridge's browser object for CEF's browser, or nil for one the bridge did not make.
ARCHCEFBrowser *BridgeBrowser(CefRefPtr<CefBrowser> browser) {
    if (!browser) {
        return nil;
    }
    for (ARCHCEFBrowser *candidate in gBrowsers) {
        CefRefPtr<CefBrowser> own = [candidate cefBrowser];
        if (own && own->IsSame(browser)) {
            return candidate;
        }
    }
    return nil;
}

// The bridge's window object for CEF's window, or nil.
ARCHCEFExtensionWindow *BridgeWindow(CefRefPtr<CefExtensionWindow> window) {
    if (!window) {
        return nil;
    }
    const int identifier = window->GetIdentifier();
    for (ARCHCEFExtensionWindow *candidate in gExtensionWindows) {
        CefRefPtr<CefExtensionWindow> own = [candidate cefWindow];
        if (own && own->GetIdentifier() == identifier) {
            return candidate;
        }
    }
    return nil;
}

NSArray<NSString *> *StringsFromList(CefRefPtr<CefListValue> list) {
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    for (size_t index = 0; list && index < list->GetSize(); index++) {
        if (list->GetType(index) == VTYPE_STRING) {
            [strings addObject:ToNSString(list->GetString(index))];
        }
    }
    return strings;
}

// Calls a load's completion once on the main thread.
class ExtensionLoadCallback : public CefExtensionLoadCallback {
  public:
    explicit ExtensionLoadCallback(void (^completion)(NSString *_Nullable, NSString *_Nullable)) : completion_([completion copy]) {}

    void OnComplete(const CefString &extension_id, const CefString &error) override {
        NSString *identifier = extension_id.empty() ? nil : ToNSString(extension_id);
        NSString *message = error.empty() ? nil : ToNSString(error);
        void (^completion)(NSString *_Nullable, NSString *_Nullable) = completion_;
        completion_ = nil;
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(identifier ?: nil, identifier ? nil : (message ?: @"Chromium did not load the extension.")); });
        }
    }

  private:
    void (^completion_)(NSString *_Nullable, NSString *_Nullable);
    IMPLEMENT_REFCOUNTING(ExtensionLoadCallback);
};

// Passes the runtime's requests for one request context to its delegate. CEF calls it on the UI thread, which is the main thread.
class BridgeExtensionHandler : public CefExtensionRuntimeHandler {
  public:
    explicit BridgeExtensionHandler(ARCHCEFRequestContext *owner) : owner_(owner) {}

    void Detach() {
        owner_ = nil;
        [popup_ handleClose];
        popup_ = nil;
    }

    void OnExtensionsChanged(CefRefPtr<CefExtensionRuntime> runtime) override { [Delegate() cefExtensionsDidChange]; }

    void OnActionChanged(CefRefPtr<CefExtensionRuntime> runtime, const CefString &extension_id, CefRefPtr<CefBrowser> tab) override {
        [Delegate() cefExtensionActionDidChange:ToNSString(extension_id) browser:BridgeBrowser(tab)];
    }

    // Only one popup is open at a time, so the popup that CEF names is the current one.
    bool OnShowPopup(CefRefPtr<CefExtensionRuntime> runtime, CefRefPtr<CefBrowser> tab, CefRefPtr<CefExtensionPopup> popup) override {
        id<ARCHCEFExtensionsDelegate> delegate = Delegate();
        ARCHCEFBrowser *browser = BridgeBrowser(tab);
        if (!delegate || !browser) {
            return false;
        }
        [popup_ handleClose];
        ARCHCEFExtensionPopup *shown = [[ARCHCEFExtensionPopup alloc] initWithPopup:popup];
        popup_ = shown;
        if (![delegate cefExtensionsShouldShowPopup:shown forBrowser:browser]) {
            popup_ = nil;
            return false;
        }
        return true;
    }

    void OnPopupSizeChanged(CefRefPtr<CefExtensionPopup> popup, const CefSize &size) override {
        if ([popup_.extensionIdentifier isEqualToString:ToNSString(popup->GetExtensionId())]) {
            [popup_ handleSizeChange:NSMakeSize(size.width, size.height)];
        }
    }

    void OnPopupClosed(CefRefPtr<CefExtensionPopup> popup) override {
        if ([popup_.extensionIdentifier isEqualToString:ToNSString(popup->GetExtensionId())]) {
            ARCHCEFExtensionPopup *closed = popup_;
            popup_ = nil;
            [closed handleClose];
        }
    }

    // The popup's page handles Escape itself. Other keys it did not handle reach the main menu, as the pages' unhandled keys do.
    bool OnPopupKeyEvent(CefRefPtr<CefExtensionPopup> popup, const CefKeyEvent &event, CefEventHandle os_event) override {
        NSEvent *keyEvent = CAST_CEF_EVENT_HANDLE_TO_NSEVENT(os_event);
        if (!keyEvent || keyEvent.type != NSEventTypeKeyDown) {
            return false;
        }
        return [NSApp.mainMenu performKeyEquivalent:keyEvent];
    }

    bool OnOpenTab(CefRefPtr<CefExtensionRuntime> runtime, CefRefPtr<CefExtensionWindow> window, const CefString &url, bool active, int index,
                   CefRefPtr<CefExtensionTabCallback> callback) override {
        id<ARCHCEFExtensionsDelegate> delegate = Delegate();
        if (!delegate) {
            return false;
        }
        CefRefPtr<CefExtensionTabCallback> answer = callback;
        __block BOOL answered = NO;
        return [delegate cefExtensionsOpenTabWithURL:ToNSString(url)
                                            inWindow:BridgeWindow(window)
                                              active:active
                                               index:index
                                          completion:^(ARCHCEFBrowser *browser) {
                                              if (answered) {
                                                  return;
                                              }
                                              answered = YES;
                                              if (!browser) {
                                                  answer->Continue(nullptr);
                                                  return;
                                              }
                                              gPendingTabs.push_back({answer, browser});
                                              ResolvePendingTabs();
                                          }];
    }

    void OnActivateTab(CefRefPtr<CefExtensionRuntime> runtime, CefRefPtr<CefBrowser> tab) override {
        ARCHCEFBrowser *browser = BridgeBrowser(tab);
        if (browser) {
            [Delegate() cefExtensionsActivateBrowser:browser];
        }
    }

    // A tab the app does not know closes as CEF's own default does.
    void OnCloseTab(CefRefPtr<CefExtensionRuntime> runtime, CefRefPtr<CefBrowser> tab) override {
        ARCHCEFBrowser *browser = BridgeBrowser(tab);
        id<ARCHCEFExtensionsDelegate> delegate = Delegate();
        if (browser && delegate) {
            [delegate cefExtensionsCloseBrowser:browser];
        } else if (tab) {
            tab->GetHost()->CloseBrowser(false);
        }
    }

    bool OnOpenWindow(CefRefPtr<CefExtensionRuntime> runtime, const std::vector<CefString> &urls, bool focused,
                      CefRefPtr<CefExtensionWindowCallback> callback) override {
        id<ARCHCEFExtensionsDelegate> delegate = Delegate();
        if (!delegate) {
            return false;
        }
        NSMutableArray<NSString *> *addresses = [NSMutableArray array];
        for (const CefString &url : urls) {
            [addresses addObject:ToNSString(url)];
        }
        CefRefPtr<CefExtensionWindowCallback> answer = callback;
        __block BOOL answered = NO;
        return [delegate cefExtensionsOpenWindowWithURLs:addresses
                                                 focused:focused
                                              completion:^(ARCHCEFExtensionWindow *window) {
                                                  if (answered) {
                                                      return;
                                                  }
                                                  answered = YES;
                                                  if (!window) {
                                                      answer->Continue(nullptr);
                                                      return;
                                                  }
                                                  ARCHCEFExtensionWindow *opened = window;
                                                  [opened whenTabsListed:^(BOOL listed) { answer->Continue(listed ? [opened cefWindow] : nullptr); }];
                                              }];
    }

    bool OnPrompt(CefRefPtr<CefExtensionRuntime> runtime, CefRefPtr<CefBrowser> tab, const CefString &extension_id, cef_extension_prompt_type_t type,
                  CefRefPtr<CefListValue> messages, CefRefPtr<CefExtensionPromptCallback> callback) override {
        id<ARCHCEFExtensionsDelegate> delegate = Delegate();
        if (!delegate) {
            return false;
        }
        ARCHCEFExtensionPromptKind kind = type == CEF_EXTENSION_PROMPT_RELOAD    ? ARCHCEFExtensionPromptKindReload
                                          : type == CEF_EXTENSION_PROMPT_INSTALL ? ARCHCEFExtensionPromptKindInstall
                                                                                 : ARCHCEFExtensionPromptKindPermissions;
        CefRefPtr<CefExtensionPromptCallback> answer = callback;
        __block BOOL answered = NO;
        return [delegate cefExtensionsShowPrompt:kind
                                       extension:ToNSString(extension_id)
                                         browser:BridgeBrowser(tab)
                                        messages:StringsFromList(messages)
                                      completion:^(BOOL accepted) {
                                          if (!answered) {
                                              answered = YES;
                                              answer->Continue(accepted);
                                          }
                                      }];
    }

  private:
    id<ARCHCEFExtensionsDelegate> Delegate() const { return owner_.extensionsDelegate; }

    __weak ARCHCEFRequestContext *owner_;
    ARCHCEFExtensionPopup *popup_;
    IMPLEMENT_REFCOUNTING(BridgeExtensionHandler);
};

bool gGlobalContextInitialized = false;

}  // namespace

// The calls that `CEFBridgeInternal.h` describes.
namespace cef_bridge {

void ReleaseExtensionObjects() {
    for (ARCHCEFExtensionWindow *window in gExtensionWindows.allObjects) {
        [window close];
    }
    ResolvePendingTabs();
}

void GlobalContextDidInitialize() {
    gGlobalContextInitialized = true;
    [ARCHCEFRequestContext.globalContext startExtensions];
}

void ExtensionsBrowserDidCreate(ARCHCEFBrowser *browser) {
    // Extension windows that list the browser send their tabs again now that CEF has it.
    for (ARCHCEFExtensionWindow *window in gExtensionWindows.allObjects) {
        [window browserDidCreate:browser];
    }
}

void ExtensionsBrowserWillClose(ARCHCEFBrowser *browser) {
    CancelPendingTabs(browser);
    for (ARCHCEFExtensionWindow *window in gExtensionWindows.allObjects) {
        [window browserWillClose:browser];
    }
}

}  // namespace cef_bridge

@implementation ARCHCEFRequestContext (ExtensionRuntime)

- (void)whenExtensionsReady:(void (^)(CefRefPtr<CefExtensionRuntime>))call {
    if (_extensionsReady) {
        call(_extensionRuntime);
        return;
    }
    if (!_extensionCalls) {
        _extensionCalls = [NSMutableArray array];
    }
    [_extensionCalls addObject:[call copy]];
    [self startExtensions];
}

/// The global context is ready once CEF reports it initialized; another context once Chromium reports it and its cookie store initialized, which `whenReady:` waits for.
- (void)startExtensions {
    if (_extensionsStarting || _extensionsReady || !gInitialized || (self == ARCHCEFRequestContext.globalContext && !gGlobalContextInitialized)) {
        return;
    }
    _extensionsStarting = YES;
    [self whenReady:^{
        if (self->_extensionsReady) {
            return;
        }
        CefRefPtr<CefRequestContext> context = [self cefContext];
        if (context && gInitialized) {
            self->_extensionHandler = new BridgeExtensionHandler(self);
            self->_extensionRuntime = CefExtensionRuntime::GetForContext(context, self->_extensionHandler);
        }
        [self finishStartingExtensions];
    }];
}

- (void)finishStartingExtensions {
    _extensionsReady = YES;
    NSArray *calls = _extensionCalls;
    _extensionCalls = nil;
    for (void (^call)(CefRefPtr<CefExtensionRuntime>) in calls) {
        call(_extensionRuntime);
    }
}

- (void)detachExtensions {
    if (_extensionHandler) {
        static_cast<BridgeExtensionHandler *>(_extensionHandler.get())->Detach();
    }
    _extensionHandler = nullptr;
    _extensionRuntime = nullptr;
    [self finishStartingExtensions];
}

@end

@implementation ARCHCEFRequestContext (Extensions)

- (id<ARCHCEFExtensionsDelegate>)extensionsDelegate {
    return _extensionsDelegate;
}

- (void)setExtensionsDelegate:(id<ARCHCEFExtensionsDelegate>)extensionsDelegate {
    _extensionsDelegate = extensionsDelegate;
    [self startExtensions];
}

- (void)loadExtensionAtPath:(NSString *)path completion:(void (^)(NSString *_Nullable, NSString *_Nullable))completion {
    [self whenExtensionsReady:^(CefRefPtr<CefExtensionRuntime> runtime) {
        if (!runtime) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"Chromium's extension runtime did not start."); });
            return;
        }
        runtime->LoadUnpacked(CefString(path.UTF8String), new ExtensionLoadCallback(completion));
    }];
}

- (void)removeExtension:(NSString *)identifier {
    [self whenExtensionsReady:^(CefRefPtr<CefExtensionRuntime> runtime) {
        if (runtime) {
            runtime->Uninstall(CefString(identifier.UTF8String));
        }
    }];
}

- (void)setExtension:(NSString *)identifier enabled:(BOOL)enabled {
    [self whenExtensionsReady:^(CefRefPtr<CefExtensionRuntime> runtime) {
        if (runtime) {
            runtime->SetEnabled(CefString(identifier.UTF8String), enabled);
        }
    }];
}

- (void)setExtension:(NSString *)identifier siteAccess:(ARCHCEFExtensionSiteAccess)siteAccess sites:(NSArray<NSString *> *)sites {
    std::vector<CefString> patterns;
    for (NSString *site in sites) {
        patterns.push_back(CefString(site.UTF8String));
    }
    [self whenExtensionsReady:^(CefRefPtr<CefExtensionRuntime> runtime) {
        if (runtime) {
            runtime->SetSiteAccess(CefString(identifier.UTF8String),
                                   siteAccess == ARCHCEFExtensionSiteAccessOnAllSites ? CEF_EXTENSION_SITE_ACCESS_ON_ALL_SITES : CEF_EXTENSION_SITE_ACCESS_ON_CLICK,
                                   patterns);
        }
    }];
}

- (void)extensionsWithCompletion:(void (^)(NSArray<ARCHCEFExtension *> *))completion {
    [self whenExtensionsReady:^(CefRefPtr<CefExtensionRuntime> runtime) {
        NSMutableArray<ARCHCEFExtension *> *extensions = [NSMutableArray array];
        CefRefPtr<CefListValue> list = runtime ? runtime->GetExtensions() : nullptr;
        for (size_t index = 0; list && index < list->GetSize(); index++) {
            if (list->GetType(index) == VTYPE_DICTIONARY) {
                [extensions addObject:[[ARCHCEFExtension alloc] initWithDictionary:list->GetDictionary(index)]];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(extensions); });
    }];
}

- (NSArray<ARCHCEFExtensionAction *> *)extensionActionsForBrowser:(ARCHCEFBrowser *)browser scale:(CGFloat)scale {
    CefRefPtr<CefBrowser> tab = [browser cefBrowser];
    if (!_extensionRuntime || !tab) {
        return @[];
    }
    NSMutableArray<ARCHCEFExtensionAction *> *actions = [NSMutableArray array];
    CefRefPtr<CefListValue> list = _extensionRuntime->GetActions(tab, (float)scale);
    for (size_t index = 0; list && index < list->GetSize(); index++) {
        if (list->GetType(index) == VTYPE_DICTIONARY) {
            [actions addObject:[[ARCHCEFExtensionAction alloc] initWithDictionary:list->GetDictionary(index) scale:scale]];
        }
    }
    return actions;
}

- (void)runExtensionAction:(NSString *)identifier inBrowser:(ARCHCEFBrowser *)browser {
    [self whenExtensionsReady:^(CefRefPtr<CefExtensionRuntime> runtime) {
        CefRefPtr<CefBrowser> tab = [browser cefBrowser];
        if (runtime && tab) {
            runtime->RunAction(tab, CefString(identifier.UTF8String));
        }
    }];
}

- (void)grantExtensionSiteAccess:(NSString *)identifier inBrowser:(ARCHCEFBrowser *)browser {
    [self whenExtensionsReady:^(CefRefPtr<CefExtensionRuntime> runtime) {
        CefRefPtr<CefBrowser> tab = [browser cefBrowser];
        if (runtime && tab) {
            runtime->GrantSiteAccess(tab, CefString(identifier.UTF8String));
        }
    }];
}

- (ARCHCEFExtensionWindow *)makeExtensionWindowForView:(NSView *)contentView {
    ARCHCEFExtensionWindow *window = [[ARCHCEFExtensionWindow alloc] initWithContentView:contentView];
    [gExtensionWindows addObject:window];
    __weak ARCHCEFExtensionWindow *weakWindow = window;
    [self whenExtensionsReady:^(CefRefPtr<CefExtensionRuntime> runtime) { [weakWindow attachRuntime:runtime]; }];
    return window;
}

@end

@implementation ARCHCEFExtensionWindow {
    NSView *_contentView;
    CefRefPtr<CefExtensionWindow> _window;
    /// The tabs the app listed, which hold no browser alive.
    NSPointerArray *_tabs;
    NSInteger _activeIndex;
    BOOL _focused;
    /// Set once the runtime answered, with a window or without one.
    BOOL _attached;
    BOOL _closed;
    /// The identifiers of the browsers in the last list that CEF received.
    std::vector<int> _listedBrowsers;
    NSMutableArray<void (^)(BOOL)> *_whenListed;
}

- (instancetype)initWithContentView:(NSView *)contentView {
    self = [super init];
    if (self) {
        _contentView = contentView;
        _tabs = [NSPointerArray weakObjectsPointerArray];
        _activeIndex = -1;
        _whenListed = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    if (_window) {
        _window->Close();
    }
    [self finishWaitingForTabs:NO];
}

- (void)attachRuntime:(CefRefPtr<CefExtensionRuntime>)runtime {
    if (_attached) {
        return;
    }
    _attached = YES;
    if (runtime && !_closed && gInitialized) {
        _window = runtime->CreateWindowForView(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(_contentView));
    }
    if (_window) {
        [self apply];
        if (_focused) {
            _window->SetFocused(true);
        }
    } else {
        [self finishWaitingForTabs:NO];
    }
}

- (CefRefPtr<CefExtensionWindow>)cefWindow {
    return _window;
}

- (void)whenTabsListed:(void (^)(BOOL))block {
    [_whenListed addObject:[block copy]];
    if (_closed || (_attached && !_window)) {
        [self finishWaitingForTabs:NO];
    } else if ([self listsEveryTab]) {
        [self finishWaitingForTabs:YES];
    }
}

/// Whether CEF's window exists and the tabs it last received are every tab the app listed, each created.
- (BOOL)listsEveryTab {
    if (!_window || _closed) {
        return NO;
    }
    for (NSUInteger index = 0; index < _tabs.count; index++) {
        ARCHCEFBrowser *tab = (__bridge ARCHCEFBrowser *)[_tabs pointerAtIndex:index];
        if (tab && ![self listsBrowser:tab]) {
            return NO;
        }
    }
    return YES;
}

/// Answers each wait for the tabs.
- (void)finishWaitingForTabs:(BOOL)listed {
    NSArray<void (^)(BOOL)> *blocks = _whenListed;
    _whenListed = [NSMutableArray array];
    for (void (^block)(BOOL) in blocks) {
        block(listed);
    }
}

- (void)setTabs:(NSArray<ARCHCEFBrowser *> *)tabs activeIndex:(NSInteger)activeIndex {
    _tabs = [NSPointerArray weakObjectsPointerArray];
    for (ARCHCEFBrowser *tab in tabs) {
        [_tabs addPointer:(__bridge void *)tab];
    }
    _activeIndex = activeIndex;
    [self apply];
}

/// Sends CEF the listed browsers that it has created, in order, with the active one's place among them.
- (void)apply {
    if (!_window || _closed) {
        return;
    }
    std::vector<CefRefPtr<CefBrowser>> browsers;
    std::vector<int> identifiers;
    int active = -1;
    for (NSUInteger index = 0; index < _tabs.count; index++) {
        ARCHCEFBrowser *tab = (__bridge ARCHCEFBrowser *)[_tabs pointerAtIndex:index];
        CefRefPtr<CefBrowser> browser = [tab cefBrowser];
        if (!browser) {
            continue;
        }
        if ((NSInteger)index == _activeIndex) {
            active = (int)browsers.size();
        }
        browsers.push_back(browser);
        identifiers.push_back(browser->GetIdentifier());
    }
    _listedBrowsers = identifiers;
    _window->SetTabs(browsers, active);
    ResolvePendingTabs();
    if (_whenListed.count > 0 && [self listsEveryTab]) {
        [self finishWaitingForTabs:YES];
    }
}

- (BOOL)listsBrowser:(ARCHCEFBrowser *)browser {
    CefRefPtr<CefBrowser> cefBrowser = [browser cefBrowser];
    return cefBrowser && !_closed && std::find(_listedBrowsers.begin(), _listedBrowsers.end(), cefBrowser->GetIdentifier()) != _listedBrowsers.end();
}

- (void)browserDidCreate:(ARCHCEFBrowser *)browser {
    for (NSUInteger index = 0; index < _tabs.count; index++) {
        if ([_tabs pointerAtIndex:index] == (__bridge void *)browser) {
            [self apply];
            return;
        }
    }
}

- (void)browserWillClose:(ARCHCEFBrowser *)browser {
    for (NSUInteger index = 0; _whenListed.count > 0 && index < _tabs.count; index++) {
        if ([_tabs pointerAtIndex:index] == (__bridge void *)browser) {
            [self finishWaitingForTabs:NO];
            return;
        }
    }
}

- (void)setFocused:(BOOL)focused {
    if (_focused == focused) {
        return;
    }
    _focused = focused;
    if (_window && !_closed) {
        _window->SetFocused(focused);
    }
}

- (void)close {
    if (_closed) {
        return;
    }
    _closed = YES;
    [gExtensionWindows removeObject:self];
    if (_window) {
        _window->Close();
        _window = nullptr;
    }
    _listedBrowsers.clear();
    [self finishWaitingForTabs:NO];
}

@end

@implementation ARCHCEFExtensionPopup {
    CefRefPtr<CefExtensionPopup> _popup;
    BOOL _closed;
}

- (instancetype)initWithPopup:(CefRefPtr<CefExtensionPopup>)popup {
    self = [super init];
    if (self) {
        _popup = popup;
        _extensionIdentifier = ToNSString(popup->GetExtensionId());
    }
    return self;
}

- (NSView *)view {
    if (_closed || !_popup) {
        return nil;
    }
    return CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(_popup->GetWindowHandle());
}

- (NSSize)preferredSize {
    if (_closed || !_popup) {
        return NSZeroSize;
    }
    CefSize size = _popup->GetPreferredSize();
    return NSMakeSize(size.width, size.height);
}

- (void)close {
    if (!_closed && _popup) {
        _popup->Close();
    }
}

- (void)handleSizeChange:(NSSize)size {
    if (!_closed && _sizeDidChange) {
        _sizeDidChange(size);
    }
}

- (void)handleClose {
    if (_closed) {
        return;
    }
    _closed = YES;
    void (^didClose)(void) = _didClose;
    _didClose = nil;
    _sizeDidChange = nil;
    if (didClose) {
        didClose();
    }
    _popup = nullptr;
}

@end
