// Declarations that the bridge's files share. It stays outside `include`, so Swift never sees it.
#import "CEFBridge.h"

#include "include/cef_app.h"
#include "include/cef_request_context.h"

namespace cef_bridge {

// Whether the runtime has initialized CEF and has not begun to shut it down.
extern bool gInitialized;
// Whether browsers build their accessibility trees.
extern bool gAccessibilityEnabled;
// The root cache path the runtime initialized with, standardized. Every request context's profile is a direct child of it.
extern NSString *gRootCachePath;
// Every browser, so that accessibility changes reach the open ones.
extern NSHashTable *gBrowsers;
// Every request context object, so that shutdown releases their references to CEF.
extern NSHashTable *gRequestContexts;

inline NSString *ToNSString(const CefString &value) {
    std::string utf8 = value.ToString();
    return [NSString stringWithUTF8String:utf8.c_str()] ?: @"";
}

// The process messages and keys between the browser process and the helper's renderer processes. `CEFBridgeHelper.mm` holds the renderer's side.

// CEF returns no value from `ExecuteJavaScript`, so the browser asks the page's renderer process for the theme color.
const char kThemeColorRequest[] = "ARCHThemeColorRequest";
const char kThemeColorReply[] = "ARCHThemeColorReply";

// The browser sends other scripts whose result it needs the same way. A request carries its number, the script, and a page script world or null; with a world, the script is a function to call with that world's channel. The reply carries the number, whether the script ran, and the string it returned, or null.
const char kScriptRequest[] = "ARCHScriptRequest";
const char kScriptReply[] = "ARCHScriptReply";

// A frame's audible state, and its media as the JSON text the media script writes.
const char kAudibleReport[] = "ARCHAudibleReport";
const char kMediaReport[] = "ARCHMediaReport";

// The browser passes a browser's page scripts to its renderers in the browser's extra info under this key, and in this message whenever they change.
const char kPageScriptsKey[] = "pageScripts";
const char kPageScriptsUpdate[] = "ARCHPageScriptsUpdate";
// The keys of one page script in those lists.
const char kPageScriptWorldKey[] = "world";
const char kPageScriptSourceKey[] = "source";
const char kPageScriptAtDocumentEndKey[] = "atDocumentEnd";
const char kPageScriptMainFrameOnlyKey[] = "mainFrameOnly";
// A value a page script sends carries its world, the request's number, and the JSON text. The reply carries the world, the number, and the reply's JSON text or null.
const char kPageScriptSend[] = "ARCHPageScriptSend";
const char kPageScriptReply[] = "ARCHPageScriptReply";
// A value for the listeners of a world's channel in the main frame carries the world and the JSON text.
const char kPageScriptDelivery[] = "ARCHPageScriptDelivery";

// The app of the helper's renderer processes, which `+[ARCHCEFRuntime runHelperWithArgc:argv:]` runs.
CefRefPtr<CefApp> MakeHelperApp();

}  // namespace cef_bridge

@interface ARCHCEFRequestContext ()
/// Gives the object CEF's context and that context's cookie manager.
- (void)attachContext:(CefRefPtr<CefRequestContext>)context;
/// Releases the CEF objects and runs the waiting calls. Calls after that change nothing.
- (void)detachContext;
/// The context for browsers of this profile, or null without one.
- (CefRefPtr<CefRequestContext>)cefContext;
@end

@interface ARCHCEFBrowser ()
/// Has the open browser build its accessibility tree, or stop, as `gAccessibilityEnabled` says.
- (void)applyAccessibilityState;
/// Whether CEF still has the browser, from its creation until `OnBeforeClose`.
@property (nonatomic, readonly) BOOL isOpen;
@end
