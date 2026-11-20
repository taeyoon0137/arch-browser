// One embedded browser: the `ARCHCEFBrowser` the app holds and the `CefClient` that passes CEF's callbacks to it, with the browser's downloads, back-forward list, context menus, page scripts, and popups.
#import "CEFBridgeInternal.h"

#include <dispatch/dispatch.h>

#include <algorithm>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_picture_in_picture_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request_handler.h"
#include "include/cef_values.h"

using namespace cef_bridge;

namespace {

// How long the browser waits for the reply to a `kScriptRequest`. A frame that navigates or goes away before it answers drops the request.
const int64_t kScriptReplyTimeout = 10 * NSEC_PER_SEC;

}  // namespace

#pragma mark - Download

@interface ARCHCEFDownload ()
@property (nonatomic, readwrite, copy, nullable) NSString *path;
@property (nonatomic, readwrite) int64_t receivedBytes;
@property (nonatomic, readwrite) int64_t totalBytes;
@property (nonatomic, readwrite) ARCHCEFDownloadState state;
/// Set once the app cancels the download. CEF applies a cancel later, and never to an interrupted download, so the browser stops counting it at once.
@property (nonatomic, readonly) BOOL isCancelledByApp;
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
    } else if (_isCancelledByApp) {
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
    _isCancelledByApp = YES;
    if (_state == ARCHCEFDownloadStateInterrupted) {
        self.state = ARCHCEFDownloadStateCanceled;
        // CEF keeps an interrupted download's partial file for resuming and does not cancel it, so the bridge removes the file as a cancel would.
        if (_path) {
            [[NSFileManager defaultManager] removeItemAtPath:_path error:nil];
        }
    }
    if (_callback) {
        _callback->Cancel();
    } else {
        _cancelRequested = YES;
    }
}

@end

#pragma mark - Navigation entries

@interface ARCHCEFNavigationEntry ()
- (instancetype)initWithIndex:(NSInteger)index url:(NSString *)url title:(NSString *)title;
@end

@implementation ARCHCEFNavigationEntry

- (instancetype)initWithIndex:(NSInteger)index url:(NSString *)url title:(NSString *)title {
    self = [super init];
    if (!self) {
        return nil;
    }
    _index = index;
    _url = [url copy];
    _title = [title copy];
    return self;
}

@end

namespace {

// CEF visits entries synchronously on the UI thread, which is the main thread here.
class NavigationEntryCollector : public CefNavigationEntryVisitor {
public:
    bool Visit(CefRefPtr<CefNavigationEntry> entry, bool current, int index, int total) override {
        [entries_ addObject:[[ARCHCEFNavigationEntry alloc] initWithIndex:index url:ToNSString(entry->GetURL()) title:ToNSString(entry->GetTitle())]];
        if (current) {
            current_ = index;
        }
        return true;
    }

    NSArray<ARCHCEFNavigationEntry *> *Entries() const { return entries_; }
    int Current() const { return current_; }

private:
    NSMutableArray<ARCHCEFNavigationEntry *> *entries_ = [NSMutableArray array];
    int current_ = -1;
    IMPLEMENT_REFCOUNTING(NavigationEntryCollector);
};

}  // namespace

#pragma mark - Context menu

@interface ARCHCEFContextMenuParams ()
- (instancetype)initWithParams:(CefRefPtr<CefContextMenuParams>)params frame:(CefRefPtr<CefFrame>)frame location:(NSPoint)location;
@end

@implementation ARCHCEFContextMenuParams

- (instancetype)initWithParams:(CefRefPtr<CefContextMenuParams>)params frame:(CefRefPtr<CefFrame>)frame location:(NSPoint)location {
    self = [super init];
    if (!self) {
        return nil;
    }
    _location = location;
    // CEF passes the frame the menu opened in.
    _isInMainFrame = frame && frame->IsMain();
    CefString link = params->GetUnfilteredLinkUrl();
    if ((params->GetTypeFlags() & CM_TYPEFLAG_LINK) && !link.empty()) {
        _linkURL = ToNSString(link);
    }
    CefString source = params->GetSourceUrl();
    if (!source.empty()) {
        switch (params->GetMediaType()) {
            case CM_MEDIATYPE_IMAGE:
                _imageURL = ToNSString(source);
                break;
            case CM_MEDIATYPE_VIDEO:
            case CM_MEDIATYPE_AUDIO:
                _mediaURL = ToNSString(source);
                break;
            default:
                break;
        }
    }
    _selectionText = ToNSString(params->GetSelectionText());
    _isEditable = params->IsEditable();
    CefContextMenuParams::EditStateFlags flags = params->GetEditStateFlags();
    ARCHCEFEditCommand commands = 0;
    if (flags & CM_EDITFLAG_CAN_CUT) {
        commands |= ARCHCEFEditCommandCut;
    }
    if (flags & CM_EDITFLAG_CAN_COPY) {
        commands |= ARCHCEFEditCommandCopy;
    }
    if (flags & CM_EDITFLAG_CAN_PASTE) {
        commands |= ARCHCEFEditCommandPaste;
    }
    if (flags & CM_EDITFLAG_CAN_SELECT_ALL) {
        commands |= ARCHCEFEditCommandSelectAll;
    }
    _editCommands = commands;
    _misspelledWord = ToNSString(params->GetMisspelledWord());
    std::vector<CefString> suggestions;
    params->GetDictionarySuggestions(suggestions);
    NSMutableArray<NSString *> *words = [NSMutableArray arrayWithCapacity:suggestions.size()];
    for (const CefString &word : suggestions) {
        [words addObject:ToNSString(word)];
    }
    _spellingSuggestions = words;
    return self;
}

@end

#pragma mark - Page scripts

@implementation ARCHCEFPageScript

- (instancetype)initWithWorld:(NSString *)world source:(NSString *)source runsAtDocumentEnd:(BOOL)runsAtDocumentEnd mainFrameOnly:(BOOL)mainFrameOnly {
    self = [super init];
    if (self) {
        _world = [world copy];
        _source = [source copy];
        _runsAtDocumentEnd = runsAtDocumentEnd;
        _mainFrameOnly = mainFrameOnly;
    }
    return self;
}

@end

namespace {

// The scripts as the renderer reads them with `ReadPageScripts`.
CefRefPtr<CefListValue> PageScriptList(NSArray<ARCHCEFPageScript *> *scripts) {
    CefRefPtr<CefListValue> list = CefListValue::Create();
    for (ARCHCEFPageScript *script in scripts) {
        CefRefPtr<CefDictionaryValue> entry = CefDictionaryValue::Create();
        entry->SetString(kPageScriptWorldKey, script.world.UTF8String);
        entry->SetString(kPageScriptSourceKey, script.source.UTF8String);
        entry->SetBool(kPageScriptAtDocumentEndKey, script.runsAtDocumentEnd);
        entry->SetBool(kPageScriptMainFrameOnlyKey, script.mainFrameOnly);
        list->SetDictionary(list->GetSize(), entry);
    }
    return list;
}

}  // namespace

#pragma mark - Browser

@interface ARCHCEFBrowser ()
/// Set from a dismissed dialog until the navigation the user started finishes loading, so the page cannot hold that navigation with another dialog.
@property(nonatomic, readonly) BOOL suppressesDialogs;
- (void)handleAfterCreated:(CefRefPtr<CefBrowser>)browser;
- (void)handleDoClose;
- (void)handleDevToolsClosed;
- (void)handleDialog:(ARCHCEFDialogKind)kind origin:(NSString *)origin message:(NSString *)message defaultText:(NSString *)defaultText completion:(void (^)(BOOL, NSString *_Nullable))completion;
- (void)handleLeavePageDialog:(void (^)(BOOL))completion;
- (void)handleResetDialogs;
- (void)handleFileChooser:(ARCHCEFFileChooserMode)mode
              defaultPath:(NSString *)defaultPath
            acceptedTypes:(NSArray<NSString *> *)acceptedTypes
                  pageURL:(NSString *)pageURL
               completion:(void (^)(NSArray<NSString *> *_Nullable))completion;
- (void)handleTitle:(NSString *)title;
- (void)handleFullscreen:(BOOL)isFullscreen;
- (void)handleActivate;
- (void)handleAudible:(BOOL)isAudible frame:(NSString *)frameIdentifier;
- (void)handleMedia:(NSString *)json frame:(NSString *)frameIdentifier;
- (void)handleScriptReply:(int)request succeeded:(BOOL)succeeded result:(nullable NSString *)result;
- (void)handlePageScriptMessage:(CefRefPtr<CefListValue>)arguments frame:(CefRefPtr<CefFrame>)frame;
- (void)handleFrameCreated:(CefRefPtr<CefFrame>)frame;
- (void)handleURL:(NSString *)url;
- (void)handleLoadingState:(BOOL)isLoading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)handleDocumentCommit:(NSString *)url;
- (void)handleDocumentLoadEnd;
- (void)handleFaviconURLs:(NSArray<NSString *> *)urls;
- (void)handleFindResult:(int)count activeMatchOrdinal:(int)activeMatchOrdinal finalUpdate:(BOOL)finalUpdate;
- (void)handleBeforePopup:(int)popupID
                ofBrowser:(int)browserIdentifier
                      url:(NSString *)url
              disposition:(cef_window_open_disposition_t)disposition
               windowInfo:(CefWindowInfo &)windowInfo
                   client:(CefRefPtr<CefClient> &)client
                extraInfo:(CefRefPtr<CefDictionaryValue> &)extraInfo;
- (BOOL)handleShouldOpenExternally:(NSString *)url userGesture:(BOOL)userGesture;
- (BOOL)handleShouldBrowse:(NSString *)url isRedirect:(BOOL)isRedirect userGesture:(BOOL)userGesture;
- (BOOL)handleMayOpenURL:(NSString *)url disposition:(cef_window_open_disposition_t)disposition userGesture:(BOOL)userGesture;
- (void)handleMainFrameNavigationPending:(BOOL)pending;
- (void)handleBeforeClose;
- (ARCHCEFDownload *)downloadForItem:(CefRefPtr<CefDownloadItem>)item;
- (void)handleBeforeDownload:(ARCHCEFDownload *)download
               suggestedName:(NSString *)suggestedName
                    decision:(void (^)(NSString *_Nullable, BOOL))decision;
- (void)handleDownloadUpdate:(ARCHCEFDownload *)download;
- (void)handlePermissionRequest:(ARCHCEFPermission)permissions origin:(NSString *)origin decision:(void (^)(BOOL))decision;
- (BOOL)handleShouldDownload:(NSString *)url hasDocument:(BOOL)hasDocument;
- (void)handleRenderProcessTerminated;
- (void)handleContextMenu:(CefRefPtr<CefContextMenuParams>)params frame:(CefRefPtr<CefFrame>)frame callback:(CefRefPtr<CefRunContextMenuCallback>)callback;
- (void)finishContextMenu;
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

// Maps Chromium's disposition for a popup to the bridge's. Any disposition that has no counterpart counts as a foreground tab.
ARCHCEFPopupDisposition PopupDisposition(cef_window_open_disposition_t disposition) {
    switch (disposition) {
        case CEF_WOD_NEW_BACKGROUND_TAB:
            return ARCHCEFPopupDispositionBackgroundTab;
        case CEF_WOD_NEW_POPUP:
            return ARCHCEFPopupDispositionPopup;
        case CEF_WOD_NEW_WINDOW:
            return ARCHCEFPopupDispositionWindow;
        default:
            return ARCHCEFPopupDispositionForegroundTab;
    }
}

// A popup that CEF has yet to create, and what its opener's delegate learns once CEF has created it.
struct PendingPopup {
    ARCHCEFBrowser *popup;
    __weak ARCHCEFBrowser *opener;
    NSString *targetURL;
    ARCHCEFPopupDisposition disposition;
};

// The popups that CEF has yet to create, by their opener browser's identifier and CEF's popup ID. No app object owns them yet, so each entry holds the popup's browser object, with the client CEF calls and the container view CEF adds the popup's view to, from `OnBeforePopup` until CEF creates the popup or aborts it. CEF calls both on the UI thread, which is the main thread here.
std::map<std::pair<int, int>, PendingPopup> gPendingPopups;

// Removes the popup's entry from `gPendingPopups` and returns it, or nothing for a browser that is not a pending popup.
std::optional<PendingPopup> TakePendingPopup(ARCHCEFBrowser *popup) {
    auto entry = std::find_if(gPendingPopups.begin(), gPendingPopups.end(), [&](const auto &item) { return item.second.popup == popup; });
    if (entry == gPendingPopups.end()) {
        return std::nullopt;
    }
    PendingPopup pending = std::move(entry->second);
    gPendingPopups.erase(entry);
    return pending;
}

// The browser objects whose browser CEF is creating through `CreateBrowser`, or closing because the app asked. CEF does both on later tasks and adds its view to the parent view through a handle that does not retain that view, so each object, with the client CEF calls and the parent view, stays here from `CreateBrowser` until `OnAfterCreated`, and from `close` or `tryCloseWithCompletion:` until `OnBeforeClose` or until the user chooses to stay, even after the app has released it. Popups wait in `gPendingPopups` until CEF creates them.
NSMutableSet<ARCHCEFBrowser *> *gBrowsersInTransition = [NSMutableSet set];

// Takes a closing browser's view out of its parent. CEF ends the browser only once the view is released. AppKit can hold a view that had the window's focus, as through the window's text input context, until it next updates its windows, which it does after each event. A page that closes itself while it has the focus, as a popup that its small window focused, would then stay open until the app's next event, such as another window becoming key. So the page gives up the focus and the windows update at once, as Chromium's own page view does when it goes (`-[RenderWidgetHostViewCocoa dealloc]`). The page is muted so that it is not heard while anything still holds the view.
void DetachBrowserView(CefRefPtr<CefBrowser> browser) {
    NSView *view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    NSWindow *window = view.window;
    BOOL hadFocus = [window.firstResponder isKindOfClass:NSView.class] && [(NSView *)window.firstResponder isDescendantOf:view];
    if (hadFocus) {
        [window makeFirstResponder:nil];
    }
    browser->GetHost()->SetAudioMuted(true);
    [view removeFromSuperview];
    if (hadFocus) {
        [NSApp updateWindows];
    }
}

// Forwards one browser's CEF callbacks to its `ARCHCEFBrowser`. The owner calls `Detach()` before releasing the client.
class BridgeClient : public CefClient,
                     public CefDisplayHandler,
                     public CefLifeSpanHandler,
                     public CefLoadHandler,
                     public CefFindHandler,
                     public CefDownloadHandler,
                     public CefDialogHandler,
                     public CefJSDialogHandler,
                     public CefKeyboardHandler,
                     public CefPermissionHandler,
                     public CefRequestHandler,
                     public CefContextMenuHandler,
                     public CefFrameHandler,
                     public CefPictureInPictureHandler {
public:
    explicit BridgeClient(ARCHCEFBrowser *owner) : owner_(owner) {}

    void Detach() { owner_ = nil; }

    // The view that the developer tools fill while they are open. CEF holds only a raw handle to it, so the client, which CEF keeps until the browser has closed, keeps the view until the tools or the browser close, even after the owner goes.
    NSView *DevToolsView() const { return devToolsView_; }
    void SetDevToolsView(NSView *view) { devToolsView_ = view; }

    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
    CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
    CefRefPtr<CefFrameHandler> GetFrameHandler() override { return this; }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    // The app shows a video in picture in picture in the system's window, so Chromium's own window never opens for these browsers.
    CefRefPtr<CefPictureInPictureHandler> GetPictureInPictureHandler() override { return this; }

    void OnFrameCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame) override { [owner_ handleFrameCreated:frame]; }

    // A key that the page leaves unhandled comes here before CEF offers it to the app's main menu. CEF builds the AppKit event of a key that `sendKeyEvent:…` sent without a window, while AppKit's keys carry the key window's number, so a key the bridge sent stops here and never runs a menu item.
    bool OnKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent &event, CefEventHandle os_event) override {
        NSEvent *nsEvent = CAST_CEF_EVENT_HANDLE_TO_NSEVENT(os_event);
        return nsEvent && nsEvent.windowNumber == 0;
    }

    // The app shows its own menu once CEF's current work returns, so Chromium's menu never shows. CEF's model is left as it is, because CEF asks only when the model has items.
    bool RunContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefContextMenuParams> params,
                        CefRefPtr<CefMenuModel> model, CefRefPtr<CefRunContextMenuCallback> callback) override {
        if (!owner_) {
            callback->Cancel();
            return true;
        }
        [owner_ handleContextMenu:params frame:frame callback:callback];
        return true;
    }

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
        [owner_ handleDialog:kind origin:ToNSString(origin_url) message:ToNSString(message_text) defaultText:ToNSString(default_prompt_text) completion:^(BOOL accepted, NSString *text) {
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

    // CEF asks the dialog handler of the chooser's web contents browser, then its window, then the focused browser (`file_dialog_runner.cc`). A missing handler cancels.
    // This browser's file inputs, a download's Save As, and choosers in browserless views such as an extension popup or docked DevTools can arrive here.
    // The app shows its own panel. Its callback stays alive in the block until the app answers; CEF cancels an unanswered callback when it is dropped.
    // Returning true suppresses Chromium's panel and repeat handling, even for a browser without an owner.
    // The app receives accepted types as the page names them and maps MIME types to file types itself. It does not use CEF's expansion into extensions.
    // CEF names no frame. The app uses the main frame's committed address (`GetURL()` reads `GetLastCommittedURL()`), not a pending navigation address.
    bool OnFileDialog(CefRefPtr<CefBrowser> browser, FileDialogMode mode, const CefString &title, const CefString &default_file_path,
                      const std::vector<CefString> &accept_filters, const std::vector<CefString> &accept_extensions,
                      const std::vector<CefString> &accept_descriptions, CefRefPtr<CefFileDialogCallback> callback) override {
        if (!owner_) {
            callback->Cancel();
            return true;
        }
        ARCHCEFFileChooserMode chooserMode = mode == FILE_DIALOG_OPEN_MULTIPLE ? ARCHCEFFileChooserModeOpenMultiple
                                             : mode == FILE_DIALOG_OPEN_FOLDER ? ARCHCEFFileChooserModeOpenFolder
                                             : mode == FILE_DIALOG_SAVE        ? ARCHCEFFileChooserModeSave
                                                                               : ARCHCEFFileChooserModeOpen;
        NSMutableArray<NSString *> *types = [NSMutableArray arrayWithCapacity:accept_filters.size()];
        for (const CefString &filter : accept_filters) {
            [types addObject:ToNSString(filter)];
        }
        CefRefPtr<CefFrame> mainFrame = browser->GetMainFrame();
        NSString *pageURL = mainFrame ? ToNSString(mainFrame->GetURL()) : @"";
        CefRefPtr<CefFileDialogCallback> continuation = callback;
        [owner_ handleFileChooser:chooserMode defaultPath:ToNSString(default_file_path) acceptedTypes:types pageURL:pageURL completion:^(NSArray<NSString *> *paths) {
            std::vector<CefString> files;
            for (NSString *path in paths) {
                files.push_back(CefString(path.UTF8String));
            }
            // An empty list cancels.
            continuation->Continue(files);
        }];
        return true;
    }

    // CEF also resets after every answered dialog and on every navigation, so the bridge passes the reset on only while a page dialog waits.
    void OnResetDialogState(CefRefPtr<CefBrowser> browser) override { [owner_ handleResetDialogs]; }

    bool CanDownload(CefRefPtr<CefBrowser> browser, const CefString &url, const CefString &request_method) override {
        return owner_ != nil && [owner_ handleShouldDownload:ToNSString(url) hasDocument:browser->HasDocument()];
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

    // A link with a scheme Chromium does not load goes to the app's own question instead of Chromium's. The delegate decides every other main frame navigation, and CEF asks again before each server redirect's request, with `is_redirect` set, so a hop the delegate refuses sends nothing. A frame inside the page loads without asking.
    bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request, bool user_gesture,
                        bool is_redirect) override {
        NSString *url = ToNSString(request->GetURL());
        bool cancel = owner_ != nil && [owner_ handleShouldOpenExternally:url userGesture:user_gesture];
        if (!cancel && frame->IsMain() && owner_ != nil) {
            cancel = ![owner_ handleShouldBrowse:url isRedirect:is_redirect userGesture:user_gesture];
        }
        if (!cancel && frame->IsMain()) {
            [owner_ handleMainFrameNavigationPending:YES];
        }
        return cancel;
    }

    // Alloy defaults to loading modified links in place. Let the app honor the requested tab or window instead.
    bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &target_url,
                          CefRequestHandler::WindowOpenDisposition target_disposition, bool user_gesture) override {
        return owner_ != nil && ![owner_ handleMayOpenURL:ToNSString(target_url) disposition:target_disposition userGesture:user_gesture];
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

    // A popup that the opener's delegate would adopt, that the delegate allows, and that belongs to no other app opens in a browser object of its own, which CEF creates in the opener's browsing context, so the page keeps the window `window.open` returns and the popup keeps `window.opener`. The runtime opens none while it shuts down. A Document Picture-in-Picture window would become a tab, so the page keeps its own interface instead. Returning true stops the popup.
    bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id, const CefString &target_url,
                       const CefString &target_frame_name, CefLifeSpanHandler::WindowOpenDisposition target_disposition,
                       bool user_gesture, const CefPopupFeatures &popupFeatures, CefWindowInfo &windowInfo,
                       CefRefPtr<CefClient> &client, CefBrowserSettings &settings, CefRefPtr<CefDictionaryValue> &extra_info,
                       bool *no_javascript_access) override {
        NSString *url = ToNSString(target_url);
        if (!gInitialized || target_disposition == CEF_WOD_NEW_PICTURE_IN_PICTURE || ![owner_.delegate cefBrowserCanAdoptPopup] ||
            (target_disposition == CEF_WOD_NEW_WINDOW && ![owner_ handleMayOpenURL:url disposition:target_disposition userGesture:user_gesture]) ||
            [owner_ handleShouldOpenExternally:url userGesture:user_gesture]) {
            return true;
        }
        [owner_ handleBeforePopup:popup_id
                        ofBrowser:browser->GetIdentifier()
                              url:url
                      disposition:target_disposition
                       windowInfo:windowInfo
                           client:client
                        extraInfo:extra_info];
        return false;
    }

    // CEF tells the opener, also after the opener's `OnBeforeClose`, when it could not create a popup that `OnBeforePopup` allowed.
    void OnBeforePopupAborted(CefRefPtr<CefBrowser> browser, int popup_id) override {
        gPendingPopups.erase({browser->GetIdentifier(), popup_id});
    }

    // Returning false would make CEF close the window that holds the browser's view, which is the app's window, so the answer is always true. The view leaves its parent instead, and CEF finishes closing the browser once the view is released. While the view stays, as for a page's own close that the owner refuses, CEF keeps the browser open. Without an owner, as after the app released an open browser, the client takes the view out itself.
    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        if (owner_) {
            [owner_ handleDoClose];
        } else {
            DetachBrowserView(browser);
        }
        return true;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        // CEF reports no close of tools in a view whose browser closes first. It takes their front-end's view out of the container right after this.
        FinishDevTools();
        [owner_ handleBeforeClose];
    }

    // CEF calls this on a task after the tools' contents have gone and their view has left the container, so `showDevTools` may open new tools from here on.
    void OnDevToolsInViewClosed(CefRefPtr<CefBrowser> browser) override { FinishDevTools(); }

    // Alloy style browsers leave a page's request to come to the front, as after a click on its notification, to the client (VI.8).
    void OnActivate(CefRefPtr<CefBrowser> browser) override { [owner_ handleActivate]; }

    void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString &title) override {
        [owner_ handleTitle:ToNSString(title)];
    }

    void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser, bool fullscreen) override {
        [owner_ handleFullscreen:fullscreen];
    }

    void OnMediaAccessChange(CefRefPtr<CefBrowser> browser, bool has_video_access, bool has_audio_access) override {
        [owner_.delegate cefBrowserDidChangeMediaAccessWithVideo:has_video_access audio:has_audio_access];
    }

    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefProcessId sourceProcess,
                                  CefRefPtr<CefProcessMessage> message) override {
        if (message->GetName() == kAudibleReport && frame) {
            [owner_ handleAudible:message->GetArgumentList()->GetBool(0) frame:ToNSString(frame->GetIdentifier())];
            return true;
        }
        if (message->GetName() == kMediaReport && frame) {
            [owner_ handleMedia:ToNSString(message->GetArgumentList()->GetString(0)) frame:ToNSString(frame->GetIdentifier())];
            return true;
        }
        if (message->GetName() == kScriptReply) {
            CefRefPtr<CefListValue> reply = message->GetArgumentList();
            [owner_ handleScriptReply:reply->GetInt(0) succeeded:reply->GetBool(1) result:reply->GetType(2) == VTYPE_STRING ? ToNSString(reply->GetString(2)) : nil];
            return true;
        }
        if (message->GetName() == kPageScriptSend && frame) {
            [owner_ handlePageScriptMessage:message->GetArgumentList() frame:frame];
            return true;
        }
        return false;
    }

    void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString &url) override {
        if (frame->IsMain()) {
            [owner_ handleURL:ToNSString(url)];
        }
    }

    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) override {
        if (!isLoading) {
            [owner_ handleMainFrameNavigationPending:NO];
        }
        [owner_ handleLoadingState:isLoading canGoBack:canGoBack canGoForward:canGoForward];
    }

    // CEF calls this once a navigation commits a new document, before it reports the main frame's new address, and not for navigations within the document or loads that fail.
    void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType transition_type) override {
        if (frame->IsMain()) {
            [owner_ handleMainFrameNavigationPending:NO];
            [owner_ handleDocumentCommit:ToNSString(frame->GetURL())];
        }
    }

    // CEF calls this for every frame, and also after a load that failed, with its error code, which is negative.
    void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) override {
        if (frame->IsMain() && httpStatusCode >= 0) {
            [owner_ handleDocumentLoadEnd];
        }
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

    // CEF calls these on the UI thread, which is the main thread here.
    void OnPictureInPictureStart(CefRefPtr<CefBrowser> browser, const CefSize &natural_size, const CefRect &source_rect) override {
        [owner_.delegate cefBrowserDidStartPictureInPictureWithNaturalSize:NSMakeSize(natural_size.width, natural_size.height)
                                                                 sourceRect:NSMakeRect(source_rect.x, source_rect.y, source_rect.width, source_rect.height)];
    }

    void OnPictureInPictureFrame(CefRefPtr<CefBrowser> browser, const CefAcceleratedPaintInfo &info) override {
        IOSurfaceRef surface = static_cast<IOSurfaceRef>(info.shared_texture_io_surface);
        if (!surface) {
            return;
        }
        const cef_rect_t &content = info.extra.content_rect;
        [owner_.delegate cefBrowserDidReceivePictureInPictureFrame:surface contentRect:NSMakeRect(content.x, content.y, content.width, content.height)];
    }

    void OnPictureInPicturePlaybackStateChange(CefRefPtr<CefBrowser> browser, bool playing, bool can_play_pause) override {
        [owner_.delegate cefBrowserDidChangePictureInPicturePlaying:playing canPlayPause:can_play_pause];
    }

    // Arch's engine ends a closing browser's picture in picture before `OnBeforeClose`, so the delegate learns of the end before the close.
    void OnPictureInPictureStop(CefRefPtr<CefBrowser> browser) override { [owner_.delegate cefBrowserDidStopPictureInPicture]; }

private:
    void FinishDevTools() {
        if (!devToolsView_) {
            return;
        }
        devToolsView_ = nil;
        [owner_ handleDevToolsClosed];
    }

    __unsafe_unretained ARCHCEFBrowser *owner_;
    NSView *devToolsView_ = nil;
    IMPLEMENT_REFCOUNTING(BridgeClient);
};

// Reads the finished PDF into memory, then removes CEF's temporary file.
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

// Runs the browser's screenshot requests through the DevTools protocol and passes each one's PNG, or nil, to its completion exactly once.
class BridgeDevToolsObserver : public CefDevToolsMessageObserver {
public:
    void Evaluate(CefRefPtr<CefBrowserHost> host, CefRefPtr<CefDictionaryValue> params, void (^completion)(BOOL)) {
        isSending_ = true;
        isSendingBoolean_ = true;
        int messageID = host->ExecuteDevToolsMethod(0, "Runtime.evaluate", params);
        isSending_ = false;
        isSendingBoolean_ = false;
        std::map<int, bool> early;
        early.swap(earlyBoolean_);
        if (messageID == 0) {
            completion(NO);
        } else if (auto result = early.find(messageID); result != early.end()) {
            completion(result->second);
        } else {
            pendingBoolean_[messageID] = completion;
        }
    }
    // Sends `Page.captureScreenshot` with `params`. A call that fails can answer before `ExecuteDevToolsMethod` returns, so results that come while the call is sent wait in `early_` for its message ID.
    void Capture(CefRefPtr<CefBrowserHost> host, CefRefPtr<CefDictionaryValue> params, void (^completion)(NSData *_Nullable)) {
        isSending_ = true;
        int messageID = host->ExecuteDevToolsMethod(0, "Page.captureScreenshot", params);
        isSending_ = false;
        std::map<int, NSData *> early;
        early.swap(early_);
        if (messageID == 0) {
            completion(nil);
        } else if (auto result = early.find(messageID); result != early.end()) {
            completion(result->second);
        } else {
            pending_[messageID] = completion;
        }
    }

    // Ends every request still waiting with nil, as when the browser closes or its page's process quits.
    void FinishAll() {
        std::map<int, void (^)(NSData *_Nullable)> pending;
        pending.swap(pending_);
        for (auto &entry : pending) {
            entry.second(nil);
        }
        std::map<int, void (^)(BOOL)> booleans;
        booleans.swap(pendingBoolean_);
        for (auto &entry : booleans) { entry.second(NO); }
    }

    void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success, const void *result,
                                size_t result_size) override {
        NSData *png = nil;
        bool boolean = false;
        if (success && result_size > 0) {
            NSData *json = [NSData dataWithBytesNoCopy:const_cast<void *>(result) length:result_size freeWhenDone:NO];
            NSDictionary *object = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
            id base64 = [object objectForKey:@"data"];
            if ([base64 isKindOfClass:NSString.class]) {
                png = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
            }
            id value = [[object objectForKey:@"result"] objectForKey:@"value"];
            boolean = [value isKindOfClass:NSNumber.class] && [value boolValue];
        }
        auto pendingBoolean = pendingBoolean_.find(message_id);
        if (pendingBoolean != pendingBoolean_.end()) {
            void (^completion)(BOOL) = pendingBoolean->second;
            pendingBoolean_.erase(pendingBoolean);
            completion(boolean);
            return;
        }
        auto pending = pending_.find(message_id);
        if (pending == pending_.end()) {
            if (isSending_) {
                if (isSendingBoolean_) { earlyBoolean_[message_id] = boolean; }
                else { early_[message_id] = png; }
            }
            return;
        }
        void (^completion)(NSData *_Nullable) = pending->second;
        pending_.erase(pending);
        completion(png);
    }

    // Results still pending when the agent detaches never arrive.
    void OnDevToolsAgentDetached(CefRefPtr<CefBrowser> browser) override { FinishAll(); }

private:
    std::map<int, void (^)(NSData *_Nullable)> pending_;
    std::map<int, NSData *> early_;
    std::map<int, void (^)(BOOL)> pendingBoolean_;
    std::map<int, bool> earlyBoolean_;
    bool isSending_ = false;
    bool isSendingBoolean_ = false;
    IMPLEMENT_REFCOUNTING(BridgeDevToolsObserver);
};

}  // namespace

@implementation ARCHCEFBrowser {
    CefRefPtr<BridgeClient> _client;
    CefRefPtr<CefBrowser> _browser;
    CefRefPtr<BridgeDevToolsObserver> _devToolsObserver;
    CefRefPtr<CefRegistration> _devToolsRegistration;
    NSMutableDictionary<NSNumber *, ARCHCEFDownload *> *_downloads;
    /// Set while `tryCloseWithCompletion:` waits for the page's `beforeunload` handlers.
    void (^_pendingClose)(BOOL);
    /// Set while the page waits for the answer to an `alert`, `confirm`, or `prompt` dialog.
    void (^_pendingDialog)(BOOL, NSString *_Nullable);
    /// The frame the last context menu opened on, where its edit commands run.
    CefRefPtr<CefFrame> _contextMenuFrame;
    /// Set while a context menu is open. It ends CEF's request exactly once.
    void (^_pendingContextMenu)(void);
    /// Set from the start of a main frame navigation until it commits or loading ends.
    BOOL _mainFrameNavigationPending;
    /// The frames whose media elements play sound.
    NSMutableSet<NSString *> *_audibleFrames;
    /// The completions of script requests whose replies have not come yet, by request number.
    NSMutableDictionary<NSNumber *, void (^)(BOOL, NSString *_Nullable)> *_scriptReplies;
    int _lastScriptRequest;
    NSArray<ARCHCEFPageScript *> *_pageScripts;
    /// Whether the page scripts changed after they went to the renderer in the browser's extra info.
    BOOL _pageScriptsChanged;
    /// Set from `close` or `tryCloseWithCompletion:` until the browser closes or the user chooses to stay, so that `DoClose` tells the app's closes from the page's own.
    BOOL _closeRequested;
    /// The address the app last asked to load before CEF created the browser, which loads once it has.
    NSString *_pendingURL;
    /// The answer to a service worker's request for this tab, from `continueOpenTab:` until CEF has created the browser or the app closes it first.
    CefRefPtr<CefOpenTabCallback> _openTabCallback;
}

@synthesize delegate = _delegate;
@synthesize parentView = _parentView;
@synthesize browserView = _browserView;
@synthesize isLoading = _isLoading;
@synthesize canGoBack = _canGoBack;
@synthesize canGoForward = _canGoForward;
@synthesize currentURL = _currentURL;
@synthesize title = _title;

- (instancetype)initWithParentView:(NSView *)parentView
                               url:(NSString *)url
                    requestContext:(ARCHCEFRequestContext *)requestContext
                       pageScripts:(NSArray<ARCHCEFPageScript *> *)pageScripts
                          delegate:(id<ARCHCEFBrowserDelegate>)delegate {
    self = [self initForBrowserInParentView:parentView url:url pageScripts:pageScripts delegate:delegate];
    if (!self) {
        return nil;
    }
    CefWindowInfo windowInfo;
    [self placeInWindowInfo:windowInfo];
    CefBrowserSettings settings;
    [gBrowsersInTransition addObject:self];
    if (!CefBrowserHost::CreateBrowser(windowInfo, _client, CefString(url.UTF8String), settings, [self creationExtraInfo], [requestContext cefContext])) {
        [gBrowsersInTransition removeObject:self];
    }
    return self;
}

/// Sets up the object for a browser that CEF creates in `parentView` later: through `CreateBrowser`, or as a popup.
- (instancetype)initForBrowserInParentView:(NSView *)parentView
                                       url:(NSString *)url
                               pageScripts:(NSArray<ARCHCEFPageScript *> *)pageScripts
                                  delegate:(nullable id<ARCHCEFBrowserDelegate>)delegate {
    self = [super init];
    if (!self) {
        return nil;
    }
    _parentView = parentView;
    _delegate = delegate;
    _currentURL = [url copy];
    _title = @"";
    _downloads = [NSMutableDictionary dictionary];
    _audibleFrames = [NSMutableSet set];
    _scriptReplies = [NSMutableDictionary dictionary];
    _pageScripts = [pageScripts copy];
    [gBrowsers addObject:self];
    _client = new BridgeClient(self);
    return self;
}

/// Makes CEF create the browser's view as a child that fills the parent view.
- (void)placeInWindowInfo:(CefWindowInfo &)windowInfo {
    NSRect bounds = _parentView.bounds;
    windowInfo.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(_parentView), CefRect(0, 0, (int)NSWidth(bounds), (int)NSHeight(bounds)));
}

/// What CEF passes to every renderer process that hosts one of the browser's frames, before the frame's first document: the page scripts.
- (CefRefPtr<CefDictionaryValue>)creationExtraInfo {
    CefRefPtr<CefDictionaryValue> extraInfo = CefDictionaryValue::Create();
    extraInfo->SetList(kPageScriptsKey, PageScriptList(_pageScripts));
    return extraInfo;
}

- (void)dealloc {
    [self finishContextMenu];
    [self finishScriptRequests];
    [self finishCaptures];
    if (_client) {
        _client->Detach();
    }
    // The app released an open browser without closing it. The client no longer reaches this object, so the client's `DoClose` takes the view out of its parent itself.
    if (_browser && gInitialized) {
        _browser->GetHost()->CloseBrowser(true);
    }
}

/// Takes the object out of `gBrowsersInTransition` once CEF has created or closed its browser, or the user chose to stay. The object lasts at least until the next turn of the run loop, so neither the rest of CEF's callback nor the caller loses it.
- (void)endTransition {
    if (![gBrowsersInTransition containsObject:self]) {
        return;
    }
    ARCHCEFBrowser *browser = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        // The block only keeps the object.
        (void)browser;
    });
    [gBrowsersInTransition removeObject:self];
}

- (void)handleAfterCreated:(CefRefPtr<CefBrowser>)browser {
    // A popup's entry, or for a browser from `CreateBrowser` its place in `gBrowsersInTransition`, keeps this object alive until the method returns; from then on its delegate keeps it, or the block below until it closes the browser.
    std::optional<PendingPopup> popup = TakePendingPopup(self);
    _browser = browser;
    NSView *view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    view.frame = _parentView.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _browserView = view;
    [self applyAccessibilityState];
    // A tab that a service worker asked for goes to CEF now, before its first page loads, unless nobody keeps it or the app closed it already.
    [self finishOpenTabWithBrowser:_delegate && !_closeRequested ? browser : nullptr];
    if (_pendingURL && !_closeRequested) {
        browser->GetMainFrame()->LoadURL(CefString(_pendingURL.UTF8String));
    }
    _pendingURL = nil;
    ExtensionsBrowserDidCreate(self);
    if (popup) {
        [popup->opener.delegate cefBrowserDidOpenPopup:self targetURL:popup->targetURL disposition:popup->disposition];
        // CEF activates a page, which document.hasFocus() needs, only after an address the app loads (LoadMainFrameURL) or when its window becomes key while the page holds the first responder, so a popup that opens in the key window gets neither. A UI delegate that gives the popup the keys, as a small window does through focusPage, queues that before this block, so on this turn the page holds the first responder only if it should take the keys.
        __weak ARCHCEFBrowser *weakPopup = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            ARCHCEFBrowser *popupBrowser = weakPopup;
            NSView *page = popupBrowser.browserView;
            NSWindow *window = page.window;
            if (window.isKeyWindow && [window.firstResponder isKindOfClass:NSView.class] &&
                [(NSView *)window.firstResponder isDescendantOf:page] && popupBrowser->_browser) {
                popupBrowser->_browser->GetHost()->SetFocus(true);
            }
        });
    }
    // A browser without a delegate here is one nobody keeps: a popup the opener's delegate dropped, since `OnBeforePopup` asked that delegate in the same task, or a browser whose owner went before CEF created it. It closes, as does one the app closed before then. CEF owns a popup's page only once the opener shows the popup, later in this task, and closing the popup before then crashes CEF, so the block keeps this object until the next turn of the run loop and closes the browser then.
    if (!_delegate || _closeRequested) {
        ARCHCEFBrowser *closing = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [closing close];
        });
    }
    [self endTransition];
    [_delegate cefBrowserDidCreateView];
}

- (void)applyAccessibilityState {
    if (_browser) {
        _browser->GetHost()->SetAccessibilityState(gAccessibilityEnabled ? STATE_ENABLED : STATE_DISABLED);
    }
}

- (void)handleTitle:(NSString *)title {
    _title = [title copy];
    [_delegate cefBrowserDidChangeTitle:title];
}

- (void)handleFullscreen:(BOOL)isFullscreen {
    [_delegate cefBrowserDidChangeFullscreen:isFullscreen];
}

- (void)handleActivate {
    [_delegate cefBrowserDidRequestActivation];
}

- (void)handleAudible:(BOOL)isAudible frame:(NSString *)frameIdentifier {
    BOOL wasAudible = _audibleFrames.count > 0;
    if (isAudible) {
        [_audibleFrames addObject:frameIdentifier];
    } else {
        [_audibleFrames removeObject:frameIdentifier];
    }
    if ((_audibleFrames.count > 0) != wasAudible) {
        [_delegate cefBrowserDidChangeAudible:!wasAudible];
    }
}

- (void)handleMedia:(NSString *)json frame:(NSString *)frameIdentifier {
    // The script writes `null` for a frame without media, which the parser rejects as a top-level value.
    id media = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    [_delegate cefBrowserDidChangeMedia:[media isKindOfClass:NSDictionary.class] ? media : nil frame:frameIdentifier];
}

- (void)performMediaAction:(ARCHCEFMediaAction)action inFrame:(NSString *)frameIdentifier {
    const char *name = nullptr;
    switch (action) {
        case ARCHCEFMediaActionPlay:
            name = "play";
            break;
        case ARCHCEFMediaActionPause:
            name = "pause";
            break;
        case ARCHCEFMediaActionPreviousTrack:
            name = "previoustrack";
            break;
        case ARCHCEFMediaActionNextTrack:
            name = "nexttrack";
            break;
    }
    CefRefPtr<CefFrame> frame = _browser ? _browser->GetFrameByIdentifier(CefString(frameIdentifier.UTF8String)) : nullptr;
    if (!name || !frame) {
        return;
    }
    // The media script defines this function so that pages can call it but not replace it.
    frame->ExecuteJavaScript(CefString(std::string("__archMediaControl(\"") + name + "\")"), frame->GetURL(), 0);
}

- (void)setPictureInPicturePlaying:(BOOL)playing {
    if (_browser) {
        _browser->GetHost()->SetPictureInPicturePlaying(playing);
    }
}

- (void)closePictureInPicturePausingVideo:(BOOL)pause {
    if (_browser) {
        _browser->GetHost()->ClosePictureInPicture(pause);
    }
}

- (void)exitFullscreenWillResize:(BOOL)willResize {
    if (_browser) {
        _browser->GetHost()->ExitFullscreen(willResize);
    }
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

- (void)handleDocumentCommit:(NSString *)url {
    [_delegate cefBrowserDidCommitDocument:url];
}

- (void)handleDocumentLoadEnd {
    [_delegate cefBrowserDidFinishLoadingDocument];
}

- (void)handleFaviconURLs:(NSArray<NSString *> *)urls {
    [_delegate cefBrowserDidChangeFaviconURLs:urls];
}

- (void)handleFindResult:(int)count activeMatchOrdinal:(int)activeMatchOrdinal finalUpdate:(BOOL)finalUpdate {
    [_delegate cefBrowserDidFindMatches:count activeMatchOrdinal:activeMatchOrdinal finalUpdate:finalUpdate];
}

- (BOOL)handleShouldOpenExternally:(NSString *)url userGesture:(BOOL)userGesture {
    id<ARCHCEFBrowserDelegate> delegate = _delegate;
    return delegate != nil && [delegate cefBrowserShouldOpenExternallyURL:url userGesture:userGesture];
}

- (BOOL)handleShouldBrowse:(NSString *)url isRedirect:(BOOL)isRedirect userGesture:(BOOL)userGesture {
    id<ARCHCEFBrowserDelegate> delegate = _delegate;
    return delegate == nil || [delegate cefBrowserShouldBrowseToURL:url isRedirect:isRedirect userGesture:userGesture];
}

// Alloy loads modified links in place unless the app handles their requested disposition.
- (BOOL)handleMayOpenURL:(NSString *)url disposition:(cef_window_open_disposition_t)disposition userGesture:(BOOL)userGesture {
    if (!userGesture || (disposition != CEF_WOD_NEW_WINDOW && disposition != CEF_WOD_NEW_BACKGROUND_TAB && disposition != CEF_WOD_NEW_FOREGROUND_TAB)) {
        return YES;
    }
    id<ARCHCEFBrowserDelegate> delegate = _delegate;
    return delegate == nil || [delegate cefBrowserShouldOpenURL:url disposition:PopupDisposition(disposition)];
}

/// Fills CEF's parameters for a popup the page opens: CEF creates it in this browser's browsing context, as the bridge's own browser object, with its own client and a container view of this browser's size, and its renderers start with this browser's page scripts. CEF uses this browser's request context and settings. The object waits in `gPendingPopups` until CEF creates the popup or aborts it.
- (void)handleBeforePopup:(int)popupID
                ofBrowser:(int)browserIdentifier
                      url:(NSString *)url
              disposition:(cef_window_open_disposition_t)disposition
               windowInfo:(CefWindowInfo &)windowInfo
                   client:(CefRefPtr<CefClient> &)client
                extraInfo:(CefRefPtr<CefDictionaryValue> &)extraInfo {
    NSView *container = [[NSView alloc] initWithFrame:_parentView.bounds];
    ARCHCEFBrowser *popup = [[ARCHCEFBrowser alloc] initForBrowserInParentView:container url:url pageScripts:_pageScripts delegate:nil];
    gPendingPopups[{browserIdentifier, popupID}] = {popup, self, url, PopupDisposition(disposition)};
    [popup placeInWindowInfo:windowInfo];
    client = popup->_client;
    extraInfo = [popup creationExtraInfo];
}

/// The view leaves its parent, so the browser closes. A closing browser's downloads stop (see `handleBeforeClose`), so while the runtime runs, the page's own `window.close()`, or its opener's, leaves the view in place while a download needs the browser; the delegate learns on the next turn of the run loop, outside CEF's callback, that the page closed itself.
- (void)handleDoClose {
    if (gInitialized && !_closeRequested && self.hasDownloadsInProgress) {
        __weak ARCHCEFBrowser *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.delegate cefBrowserDidClose];
        });
        return;
    }
    if (_browser) {
        DetachBrowserView(_browser);
    }
    _browserView = nil;
    [self finishPendingClose:YES];
}

- (void)finishPendingClose:(BOOL)closing {
    void (^completion)(BOOL) = _pendingClose;
    _pendingClose = nil;
    if (completion) {
        // A close the user stays from no longer counts as the app's.
        if (!closing) {
            _closeRequested = NO;
            [self endTransition];
        }
        completion(closing);
    }
}

- (void)handleDialog:(ARCHCEFDialogKind)kind origin:(NSString *)origin message:(NSString *)message defaultText:(NSString *)defaultText completion:(void (^)(BOOL, NSString *_Nullable))completion {
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
    [delegate cefBrowserRunDialog:kind origin:origin message:message defaultText:defaultText completion:answer];
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
    void (^answer)(BOOL, NSString *_Nullable) = _pendingDialog;
    if (!answer) {
        return;
    }
    answer(NO, nil);
    [_delegate cefBrowserDidResetDialogs];
}

- (void)handleFileChooser:(ARCHCEFFileChooserMode)mode
              defaultPath:(NSString *)defaultPath
            acceptedTypes:(NSArray<NSString *> *)acceptedTypes
                  pageURL:(NSString *)pageURL
               completion:(void (^)(NSArray<NSString *> *_Nullable))completion {
    id<ARCHCEFBrowserDelegate> delegate = _delegate;
    if (!delegate) {
        completion(nil);
        return;
    }
    // CEF ignores a second answer, so a delegate that answers twice changes nothing.
    [delegate cefBrowserRunFileChooser:mode defaultPath:defaultPath acceptedTypes:acceptedTypes pageURL:pageURL completion:completion];
}

- (void)handleBeforeClose {
    // The delegate's close handler can release the last reference to this object, as for a page that closed itself, which nothing put in `gBrowsersInTransition`, and the client reaches the object without retaining it. This reference keeps it until the method returns.
    ARCHCEFBrowser *keepAlive __attribute__((objc_precise_lifetime)) = self;
    [self finishContextMenu];
    [self finishScriptRequests];
    ExtensionsBrowserWillClose(self);
    [self finishCaptures];
    _devToolsRegistration = nullptr;
    _devToolsObserver = nullptr;
    _contextMenuFrame = nullptr;
    _browser = nullptr;
    _browserView = nil;
    // `+shutdown` clears `gInitialized` before it closes every browser at quit. Those closes are not reported, so the session keeps the tabs and saves them.
    if (gInitialized) {
        // CEF reports nothing more about the browser's downloads but lets them run on, so the bridge cancels the ones still in progress or interrupted, as when the app closes the browser during one. Cancelling an interrupted one also removes its partial file, which no other browser can resume.
        for (ARCHCEFDownload *download in _downloads.allValues) {
            if (download.state == ARCHCEFDownloadStateInProgress || download.state == ARCHCEFDownloadStateInterrupted) {
                [download cancel];
                download.state = ARCHCEFDownloadStateCanceled;
                [_delegate cefBrowserDidUpdateDownload:download];
            }
        }
        [_delegate cefBrowserDidClose];
    }
    [self endTransition];
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
    if (!_browser) {
        return NO;
    }
    for (ARCHCEFDownload *download in _downloads.allValues) {
        // An interrupted download can still resume, but only through this browser.
        if (!download.isCancelledByApp && (download.state == ARCHCEFDownloadStateInProgress || download.state == ARCHCEFDownloadStateInterrupted)) {
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
    // A page whose process quit plays nothing, and its frames never report again.
    if (_audibleFrames.count > 0) {
        [_audibleFrames removeAllObjects];
        [_delegate cefBrowserDidChangeAudible:NO];
    }
    [self finishScriptRequests];
    [self finishCaptures];
    [_delegate cefBrowserRenderProcessDidTerminate];
}

- (void)handleContextMenu:(CefRefPtr<CefContextMenuParams>)params frame:(CefRefPtr<CefFrame>)frame callback:(CefRefPtr<CefRunContextMenuCallback>)callback {
    // An earlier menu that never closed ends first.
    [self finishContextMenu];
    // CEF gives the point from the top-left corner of its view, which fills the parent view.
    NSPoint point = NSMakePoint(params->GetXCoord(), params->GetYCoord());
    if (!_parentView.isFlipped) {
        point.y = NSHeight(_parentView.bounds) - point.y;
    }
    ARCHCEFContextMenuParams *values = [[ARCHCEFContextMenuParams alloc] initWithParams:params frame:frame location:point];
    CefRefPtr<CefRunContextMenuCallback> continuation = callback;
    __weak ARCHCEFBrowser *weakSelf = self;
    __block BOOL finished = NO;
    void (^finish)(void) = ^{
        if (finished) {
            return;
        }
        finished = YES;
        ARCHCEFBrowser *strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf->_pendingContextMenu = nil;
        }
        // The app runs its items itself, so CEF's own commands never run.
        continuation->Cancel();
    };
    _pendingContextMenu = finish;
    _contextMenuFrame = frame;
    // A main-queue block would hold the serial queue, and the CEF work scheduled on it, while the menu tracks. A run loop block in the default mode runs once CEF's current work returns.
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
        ARCHCEFBrowser *strongSelf = weakSelf;
        id<ARCHCEFBrowserDelegate> delegate = strongSelf ? strongSelf->_delegate : nil;
        if (!delegate || !strongSelf->_browserView) {
            finish();
            return;
        }
        CefScopedSendingEvent sendingEvent;
        [delegate cefBrowserRunContextMenu:values completion:finish];
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

- (void)finishContextMenu {
    void (^finish)(void) = _pendingContextMenu;
    _pendingContextMenu = nil;
    if (finish) {
        finish();
    }
}

- (void)performEditCommand:(ARCHCEFEditCommand)command {
    if (!_browser) {
        return;
    }
    CefRefPtr<CefFrame> frame = _contextMenuFrame && _contextMenuFrame->IsValid() ? _contextMenuFrame : _browser->GetFocusedFrame();
    if (!frame) {
        return;
    }
    if (command & ARCHCEFEditCommandCut) {
        frame->Cut();
    } else if (command & ARCHCEFEditCommandCopy) {
        frame->Copy();
    } else if (command & ARCHCEFEditCommandPaste) {
        frame->Paste();
    } else if (command & ARCHCEFEditCommandSelectAll) {
        frame->SelectAll();
    }
}

- (BOOL)setContextMenuPasswordAutoFill:(BOOL)enabled {
    return _browser && _browser->GetHost()->SetContextMenuPasswordAutoFill(enabled);
}

// A browser that CEF has created, or one whose creation will not come, answers at once; a browser that CEF has created may already have its first page, and CEF then opens nothing for the request.
- (void)continueOpenTab:(CefRefPtr<CefOpenTabCallback>)callback {
    if (_browser || _closeRequested || ![gBrowsersInTransition containsObject:self]) {
        callback->Continue(_closeRequested ? nullptr : _browser);
        return;
    }
    [self finishOpenTabWithBrowser:nullptr];
    _openTabCallback = callback;
}

- (void)finishOpenTabWithBrowser:(CefRefPtr<CefBrowser>)browser {
    CefRefPtr<CefOpenTabCallback> callback = _openTabCallback;
    _openTabCallback = nullptr;
    if (callback) {
        callback->Continue(browser);
    }
}

- (void)replaceMisspellingWithWord:(NSString *)word {
    if (_browser) {
        _browser->GetHost()->ReplaceMisspelling(CefString(word.UTF8String));
    }
}

/// CEF's event flags for the modifiers.
static uint32_t InputEventFlags(ARCHCEFInputModifiers modifiers) {
    uint32_t flags = EVENTFLAG_NONE;
    if (modifiers & ARCHCEFInputModifierShift) {
        flags |= EVENTFLAG_SHIFT_DOWN;
    }
    if (modifiers & ARCHCEFInputModifierControl) {
        flags |= EVENTFLAG_CONTROL_DOWN;
    }
    if (modifiers & ARCHCEFInputModifierOption) {
        flags |= EVENTFLAG_ALT_DOWN;
    }
    if (modifiers & ARCHCEFInputModifierCommand) {
        flags |= EVENTFLAG_COMMAND_DOWN;
    }
    return flags;
}

static CefMouseEvent InputMouseEvent(NSPoint point, uint32_t flags) {
    CefMouseEvent event;
    event.x = (int)lround(point.x);
    event.y = (int)lround(point.y);
    event.modifiers = flags;
    return event;
}

- (BOOL)sendMouseMoveTo:(NSPoint)point modifiers:(ARCHCEFInputModifiers)modifiers {
    if (!_browser) {
        return NO;
    }
    _browser->GetHost()->SendMouseMoveEvent(InputMouseEvent(point, InputEventFlags(modifiers)), false);
    return YES;
}

/// A press carries the pressed button among its flags, as AppKit's presses do, so the page reads it from the event's `buttons`.
- (BOOL)sendMouseClickAt:(NSPoint)point mouseUp:(BOOL)mouseUp clickCount:(NSInteger)clickCount modifiers:(ARCHCEFInputModifiers)modifiers {
    if (!_browser) {
        return NO;
    }
    uint32_t flags = InputEventFlags(modifiers) | (mouseUp ? 0 : EVENTFLAG_LEFT_MOUSE_BUTTON);
    _browser->GetHost()->SendMouseClickEvent(InputMouseEvent(point, flags), MBT_LEFT, mouseUp, (int)clickCount);
    return YES;
}

/// CEF's deltas follow AppKit's scrolling deltas, which are positive toward the top and the left.
- (BOOL)sendMouseWheelAt:(NSPoint)point deltaX:(NSInteger)deltaX deltaY:(NSInteger)deltaY modifiers:(ARCHCEFInputModifiers)modifiers {
    if (!_browser) {
        return NO;
    }
    _browser->GetHost()->SendMouseWheelEvent(InputMouseEvent(point, InputEventFlags(modifiers)), (int)-deltaX, (int)-deltaY);
    return YES;
}

- (BOOL)sendKeyEvent:(ARCHCEFKeyEventKind)kind keyCode:(int)keyCode character:(unichar)character unmodifiedCharacter:(unichar)unmodifiedCharacter modifiers:(ARCHCEFInputModifiers)modifiers {
    if (!_browser) {
        return NO;
    }
    CefKeyEvent event;
    switch (kind) {
    case ARCHCEFKeyEventKindDown:
        event.type = KEYEVENT_RAWKEYDOWN;
        break;
    case ARCHCEFKeyEventKindCharacter:
        event.type = KEYEVENT_CHAR;
        break;
    case ARCHCEFKeyEventKindUp:
        event.type = KEYEVENT_KEYUP;
        break;
    }
    event.modifiers = InputEventFlags(modifiers);
    event.native_key_code = keyCode;
    event.character = character;
    event.unmodified_character = unmodifiedCharacter;
    _browser->GetHost()->SendKeyEvent(event);
    return YES;
}

- (void)addWordToDictionary:(NSString *)word {
    if (_browser) {
        _browser->GetHost()->AddWordToDictionary(CefString(word.UTF8String));
    }
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

// `CreateBrowser` returns before CEF creates the browser, so a load the app asks for meanwhile, such as an address the user enters while a tab's page starts, waits for `OnAfterCreated`. The latest one wins.
- (void)loadURL:(NSString *)url {
    [self dismissPendingDialog];
    if (_browser) {
        _browser->GetMainFrame()->LoadURL(CefString(url.UTF8String));
    } else if (!_closeRequested) {
        _pendingURL = [url copy];
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

- (void)startDownloadWithURL:(NSString *)url {
    if (_browser) {
        _browser->GetHost()->StartDownload(CefString(url.UTF8String));
    }
}

- (void)goBack {
    // Without an entry nothing loads, and the dialog would stay suppressed until another load ends.
    if (!_browser || !_browser->CanGoBack()) {
        return;
    }
    [self dismissPendingDialog];
    if (_browser) {
        _browser->GoBack();
    }
}

- (void)goForward {
    if (!_browser || !_browser->CanGoForward()) {
        return;
    }
    [self dismissPendingDialog];
    if (_browser) {
        _browser->GoForward();
    }
}

- (void)evaluateScript:(NSString *)script completion:(void (^)(NSString *_Nullable))completion {
    [self requestScript:script world:nil completion:^(BOOL succeeded, NSString *_Nullable result) {
        completion(succeeded ? result : nil);
    }];
}

- (void)callPageScriptFunction:(NSString *)function inWorld:(NSString *)world completion:(void (^)(BOOL, NSString *_Nullable))completion {
    [self requestScript:function world:world completion:completion];
}

/// Asks the main frame's renderer to evaluate `script`, or, with a world, to call it with that world's channel, and passes on the reply.
- (void)requestScript:(NSString *)script world:(nullable NSString *)world completion:(void (^)(BOOL, NSString *_Nullable))completion {
    CefRefPtr<CefFrame> frame = _browser ? _browser->GetMainFrame() : nullptr;
    if (!frame) {
        completion(NO, nil);
        return;
    }
    int request = ++_lastScriptRequest;
    _scriptReplies[@(request)] = [completion copy];
    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kScriptRequest);
    message->GetArgumentList()->SetInt(0, request);
    message->GetArgumentList()->SetString(1, CefString(script.UTF8String));
    if (world) {
        message->GetArgumentList()->SetString(2, CefString(world.UTF8String));
    } else {
        message->GetArgumentList()->SetNull(2);
    }
    frame->SendProcessMessage(PID_RENDERER, message);
    __weak ARCHCEFBrowser *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kScriptReplyTimeout), dispatch_get_main_queue(), ^{
        [weakSelf handleScriptReply:request succeeded:NO result:nil];
    });
}

- (void)handleScriptReply:(int)request succeeded:(BOOL)succeeded result:(nullable NSString *)result {
    void (^completion)(BOOL, NSString *_Nullable) = _scriptReplies[@(request)];
    if (!completion) {
        return;
    }
    [_scriptReplies removeObjectForKey:@(request)];
    completion(succeeded, result);
}

/// Ends every request still waiting for a reply, as when the page's process quits or the browser goes.
- (void)finishScriptRequests {
    NSArray<void (^)(BOOL, NSString *_Nullable)> *completions = _scriptReplies.allValues;
    [_scriptReplies removeAllObjects];
    for (void (^completion)(BOOL, NSString *_Nullable) in completions) {
        completion(NO, nil);
    }
}

- (void)setPageScripts:(NSArray<ARCHCEFPageScript *> *)pageScripts {
    _pageScripts = [pageScripts copy];
    _pageScriptsChanged = YES;
    if (!_browser) {
        return;
    }
    // Each frame's renderer process keeps the scripts for the whole browser, so frames that share a process receive the same list more than once.
    std::vector<CefString> identifiers;
    _browser->GetFrameIdentifiers(identifiers);
    for (const CefString &identifier : identifiers) {
        [self sendPageScriptsToFrame:_browser->GetFrameByIdentifier(identifier)];
    }
}

/// A frame created after the scripts changed may be the first of the browser in its renderer process, which then has only the scripts of the browser's extra info. CEF queues the message until the frame attaches and does not order it before the frame's first document, so that document may still run the extra info's scripts (needs verification).
- (void)handleFrameCreated:(CefRefPtr<CefFrame>)frame {
    if (_pageScriptsChanged) {
        [self sendPageScriptsToFrame:frame];
    }
}

- (void)sendPageScriptsToFrame:(CefRefPtr<CefFrame>)frame {
    if (!frame) {
        return;
    }
    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kPageScriptsUpdate);
    message->GetArgumentList()->SetList(0, PageScriptList(_pageScripts));
    frame->SendProcessMessage(PID_RENDERER, message);
}

- (void)handlePageScriptMessage:(CefRefPtr<CefListValue>)arguments frame:(CefRefPtr<CefFrame>)frame {
    NSString *world = ToNSString(arguments->GetString(0));
    int request = arguments->GetInt(1);
    void (^reply)(NSString *_Nullable) = ^(NSString *_Nullable json) {
        CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kPageScriptReply);
        message->GetArgumentList()->SetString(0, CefString(world.UTF8String));
        message->GetArgumentList()->SetInt(1, request);
        if (json) {
            message->GetArgumentList()->SetString(2, CefString(json.UTF8String));
        } else {
            message->GetArgumentList()->SetNull(2);
        }
        // A frame that went away discards the message.
        frame->SendProcessMessage(PID_RENDERER, message);
    };
    id<ARCHCEFBrowserDelegate> delegate = _delegate;
    if (!delegate) {
        reply(nil);
        return;
    }
    [delegate cefBrowserDidReceivePageScriptMessage:ToNSString(arguments->GetString(2))
                                              world:world
                                           frameURL:ToNSString(frame->GetURL())
                                        isMainFrame:frame->IsMain()
                                              reply:reply];
}

- (void)postPageScriptMessage:(NSString *)json toWorld:(NSString *)world {
    CefRefPtr<CefFrame> frame = _browser ? _browser->GetMainFrame() : nullptr;
    if (!frame) {
        return;
    }
    CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kPageScriptDelivery);
    message->GetArgumentList()->SetString(0, CefString(world.UTF8String));
    message->GetArgumentList()->SetString(1, CefString(json.UTF8String));
    frame->SendProcessMessage(PID_RENDERER, message);
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

- (void)showDevTools {
    if (!_browser) {
        return;
    }
    CefRefPtr<CefBrowserHost> host = _browser->GetHost();
    if (_client->DevToolsView()) {
        // Open tools take focus. Closing tools ignore the call until CEF reports their close.
        if (host->HasDevTools()) {
            host->ShowDevTools(CefWindowInfo(), nullptr, CefBrowserSettings(), CefPoint());
        }
        return;
    }
    // CEF fills the container with the tools' front-end, without a browser of its own, and the app places the container beside the page or in a window.
    NSView *container = [[NSView alloc] initWithFrame:_parentView.bounds];
    container.wantsLayer = YES;
    CefWindowInfo windowInfo;
    windowInfo.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(container), CefRect(0, 0, (int)NSWidth(container.bounds), (int)NSHeight(container.bounds)));
    host->ShowDevTools(windowInfo, nullptr, CefBrowserSettings(), CefPoint());
    // On the main thread CEF has shown the tools when the call returns, unless it refused them, as policy can.
    if (host->HasDevTools()) {
        _client->SetDevToolsView(container);
        [_delegate cefBrowserDevToolsDidOpenView:container];
    }
}

- (void)handleDevToolsClosed {
    [_delegate cefBrowserDevToolsDidClose];
}

- (BOOL)showsDevToolsInView {
    return _client && _client->DevToolsView() != nil;
}

- (void)closeDevTools {
    if (_browser) {
        _browser->GetHost()->CloseDevTools();
    }
}

- (BOOL)hasDevTools {
    return _browser && _browser->GetHost()->HasDevTools();
}

- (void)printToPDFWithCompletion:(void (^)(NSData *_Nullable))completion {
    if (!_browser) {
        completion(nil);
        return;
    }
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"arch-%@.pdf", NSUUID.UUID.UUIDString]];
    // CEF lays out on US Letter by default. Use the system's default paper, in inches, as WebKit's PDF and the print panel do.
    NSSize paper = NSPrintInfo.sharedPrintInfo.paperSize;
    CefPdfPrintSettings settings;
    settings.paper_width = paper.width / 72.0;
    settings.paper_height = paper.height / 72.0;
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
    _devToolsObserver->Capture(host, params, completion);
}

- (void)evaluateWithUserGesture:(NSString *)script completion:(void (^)(BOOL))completion {
    if (!_browser) { completion(NO); return; }
    CefRefPtr<CefBrowserHost> host = _browser->GetHost();
    if (!_devToolsObserver) {
        _devToolsObserver = new BridgeDevToolsObserver;
        _devToolsRegistration = host->AddDevToolsMessageObserver(_devToolsObserver);
    }
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("expression", CefString(script.UTF8String));
    params->SetBool("userGesture", true);
    params->SetBool("awaitPromise", true);
    params->SetBool("returnByValue", true);
    _devToolsObserver->Evaluate(host, params, completion);
}

/// Ends every capture still waiting for its result, as when the page's process quits or the browser goes.
- (void)finishCaptures {
    if (_devToolsObserver) {
        _devToolsObserver->FinishAll();
    }
}

- (NSArray<ARCHCEFNavigationEntry *> *)navigationEntries {
    if (!_browser) {
        return @[];
    }
    CefRefPtr<NavigationEntryCollector> collector = new NavigationEntryCollector;
    _browser->GetHost()->GetNavigationEntries(collector, false);
    return collector->Entries();
}

// Requesting only the current entry gives it index 0, so read the whole list to find its position.
- (NSInteger)currentNavigationEntryIndex {
    if (!_browser) {
        return -1;
    }
    CefRefPtr<NavigationEntryCollector> collector = new NavigationEntryCollector;
    _browser->GetHost()->GetNavigationEntries(collector, false);
    return collector->Current();
}

- (void)handleMainFrameNavigationPending:(BOOL)pending {
    _mainFrameNavigationPending = pending;
}

// Once a tab has 50 entries, Chromium drops the oldest and shifts the rest, so check that the entry still has the URL the caller read.
- (BOOL)entryAtIndex:(NSInteger)index hasURL:(NSString *)url currentIndex:(NSInteger *)current {
    CefRefPtr<NavigationEntryCollector> collector = new NavigationEntryCollector;
    _browser->GetHost()->GetNavigationEntries(collector, false);
    NSArray<ARCHCEFNavigationEntry *> *entries = collector->Entries();
    *current = collector->Current();
    return *current >= 0 && index != *current && index >= 0 && index < (NSInteger)entries.count && [entries[index].url isEqualToString:url];
}

// CEF has no call to navigate to a list index. The DevTools protocol's call would leave a debugger attached to the tab, preventing Chromium from timing out hung pages. Use the page's `history.go` instead.
- (void)goToNavigationEntryAtIndex:(NSInteger)index url:(NSString *)url {
    NSInteger current = -1;
    if (!_browser || ![self entryAtIndex:index hasURL:url currentIndex:&current]) {
        return;
    }
    [self dismissPendingDialog];
    // Chromium ignores page history requests during another main frame navigation. Stopping it also removes a pending back or forward entry from the current position, so read the list again.
    if (_mainFrameNavigationPending) {
        _browser->StopLoad();
        if (![self entryAtIndex:index hasURL:url currentIndex:&current]) {
            return;
        }
    }
    CefRefPtr<CefFrame> frame = _browser->GetMainFrame();
    // A page can declare its own global `history`, but not `window`.
    frame->ExecuteJavaScript(CefString("window.history.go(" + std::to_string(index - current) + ")"), frame->GetURL(), 0);
}

- (BOOL)isOpen {
    return _browser != nullptr;
}

- (CefRefPtr<CefBrowser>)cefBrowser {
    return _browser;
}

// Before CEF has created the browser, the request waits for `OnAfterCreated`.
- (void)close {
    _closeRequested = YES;
    if (_browser) {
        [gBrowsersInTransition addObject:self];
        _browser->GetHost()->CloseBrowser(true);
    } else {
        [self finishOpenTabWithBrowser:nullptr];
    }
}

- (void)tryCloseWithCompletion:(void (^)(BOOL))completion {
    _closeRequested = YES;
    if (!_browser) {
        [self finishOpenTabWithBrowser:nullptr];
        completion(YES);
        return;
    }
    _pendingClose = [completion copy];
    [gBrowsersInTransition addObject:self];
    _browser->GetHost()->CloseBrowser(false);
}

@end
