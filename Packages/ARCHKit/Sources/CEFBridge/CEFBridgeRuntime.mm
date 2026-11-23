// Initializes the Chromium Embedded Framework (CEF), runs its message pump on the main run loop, and shuts it down. The helper processes start here as well.
#import "CEFBridgeInternal.h"

#include <crt_externs.h>
#include <dispatch/dispatch.h>

#include <cstdlib>
#include <cstring>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_sandbox_mac.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

using namespace cef_bridge;

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

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)accessibilitySetValue:(id)value forAttribute:(NSString *)attribute {
    if (self.accessibilityAttributeHandler) {
        self.accessibilityAttributeHandler(attribute, value);
    }
    [super accessibilitySetValue:value forAttribute:attribute];
}
#pragma clang diagnostic pop

- (void)terminate:(id)sender {
    // A key that a Chromium page or an extension popup leaves unhandled reaches the main menu inside CEF's work, where shutting CEF down could run none of the closes it waits for. Such a quit runs again from a timer once that work has returned; a timer, unlike a main queue block, leaves the main queue free to run the blocks that close browsers while shutdown waits for them.
    if (ARCHCEFRuntime.isRunningWork) {
        [self performSelector:@selector(terminate:) withObject:sender afterDelay:0];
        return;
    }
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
// otherwise on a one-shot timer no later than 33 ms in the run loop's common modes, so that the work goes on while a
// menu tracks or an app-modal alert shows, and again at once when a request arrives during a run.
@interface ARCHCEFPump : NSObject
+ (instancetype)shared;
/// Whether the pump is running `CefDoMessageLoopWork()`.
@property (nonatomic, readonly) BOOL isActive;
- (void)scheduleWork:(int64_t)delayMilliseconds;
@end

@implementation ARCHCEFPump {
    NSTimer *_timer;
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
    _timer = [NSTimer timerWithTimeInterval:delay / 1000.0 target:self selector:@selector(timerFired:) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
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

// The client of the browsers that Chromium's own interface opens in windows of its own, as `identity.launchWebAuthFlow` does. Arch shows none of them: each one is logged and closed once CEF has created it. Without a default client such a browser would get no callbacks and hold up shutdown until someone closed its window.
class UnshownBrowserClient : public CefClient, public CefLifeSpanHandler {
public:
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        gUnshownBrowsers++;
        CefRefPtr<CefFrame> frame = browser->GetMainFrame();
        NSString *host = frame ? [NSURL URLWithString:ToNSString(frame->GetURL())].host : nil;
        NSLog(@"Arch closed a window that Chromium opened of its own%@.", host.length > 0 ? [@" for " stringByAppendingString:host] : @"");
        // The close waits for the next turn of the run loop, so that CEF finishes creating the browser first.
        CefRefPtr<CefBrowser> unshown = browser;
        dispatch_async(dispatch_get_main_queue(), ^{ unshown->GetHost()->CloseBrowser(true); });
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override { gUnshownBrowsers--; }

private:
    IMPLEMENT_REFCOUNTING(UnshownBrowserClient);
};

class BridgeApp : public CefApp, public CefBrowserProcessHandler {
public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    // Every browser of Arch's has its own client, so only the browsers of Chromium's own windows get this one.
    CefRefPtr<CefClient> GetDefaultClient() override { return new UnshownBrowserClient(); }

    // Runs on the UI thread, which is the main thread, once the global context's profile has initialized.
    void OnContextInitialized() override {
        dispatch_async(dispatch_get_main_queue(), ^{
            GlobalContextDidInitialize();
            [ARCHCEFRequestContext.globalContext attachHandlerContext];
        });
    }

    // CEF calls this from any thread, including the main thread from inside one of its own API calls such as `LoadURL`.
    // Running `CefDoMessageLoopWork()` there re-enters the message loop and hangs, so the work always waits for the next
    // pass of the main run loop, as the CEF client sample does.
    void OnScheduleMessagePumpWork(int64_t delay_ms) override {
        dispatch_async(dispatch_get_main_queue(), ^{ [[ARCHCEFPump shared] scheduleWork:delay_ms]; });
    }

    void OnBeforeCommandLineProcessing(const CefString &process_type, CefRefPtr<CefCommandLine> command_line) override {
        if (process_type.empty()) {
            // Without it Chromium shows its own sign-in window and never asks GetAuthCredentials.
            command_line->AppendSwitch("disable-chrome-login-prompt");
            // The app feeds Now Playing and answers the media keys for both engines. Chromium's own media controls would use the same process-wide centers, so they stay off.
            std::string disabled = command_line->GetSwitchValue("disable-features").ToString();
            command_line->AppendSwitchWithValue("disable-features", disabled.empty() ? "HardwareMediaKeyHandling" : disabled + ",HardwareMediaKeyHandling");
        }
    }

private:
    IMPLEMENT_REFCOUNTING(BridgeApp);
};

}  // namespace

// The shared state that `CEFBridgeInternal.h` describes.
namespace cef_bridge {

bool gInitialized = false;
bool gAccessibilityEnabled = false;
NSString *gRootCachePath;
NSHashTable *gBrowsers = [NSHashTable weakObjectsHashTable];
NSHashTable *gRequestContexts = [NSHashTable weakObjectsHashTable];
int gUnshownBrowsers = 0;

NSString *CanonicalCacheDirectory(NSString *path) {
    char *resolved = realpath(path.fileSystemRepresentation, nullptr);
    if (!resolved) {
        return nil;
    }
    NSString *directory = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
    free(resolved);
    return directory;
}

}  // namespace cef_bridge

#pragma mark - Runtime

@implementation ARCHCEFRuntime

+ (void)setAccessibilityEnabled:(BOOL)enabled {
    gAccessibilityEnabled = enabled;
    for (ARCHCEFBrowser *browser in gBrowsers) {
        [browser applyAccessibilityState];
    }
}

+ (BOOL)initializeWithFrameworkPath:(NSString *)frameworkPath
                         helperPath:(NSString *)helperPath
                          cachePath:(NSString *)cachePath
                 acceptLanguageList:(NSString *)acceptLanguageList
                             locale:(NSString *)locale {
    if (gInitialized) {
        return YES;
    }
    NSString *library = [frameworkPath stringByAppendingPathComponent:@"Chromium Embedded Framework"];
    if (!cef_load_library(library.fileSystemRepresentation)) {
        return NO;
    }
    CefMainArgs mainArgs(*_NSGetArgc(), *_NSGetArgv());
    CefSettings settings;
    settings.external_message_pump = true;
    // Chromium's log would keep pages' console messages with their script addresses, and downloads' file names, in `chrome_debug.log` under the root cache path, outside every Persona and out of reach of clearing history or website data. The browser and its helpers write no log, and the file an earlier build left goes.
    settings.log_severity = LOGSEVERITY_DISABLE;
    [[NSFileManager defaultManager] removeItemAtPath:[cachePath stringByAppendingPathComponent:@"chrome_debug.log"] error:nil];
    CefString(&settings.framework_dir_path) = frameworkPath.UTF8String;
    // CEF compares its root to each request context's path. Use one spelling when the profile lives behind a symlink.
    NSString *root = CanonicalCacheDirectory(cachePath);
    if (!root) {
        return NO;
    }
    CefString(&settings.root_cache_path) = root.UTF8String;
    CefString(&settings.cache_path) = root.UTF8String;
    if (helperPath.length > 0) {
        CefString(&settings.browser_subprocess_path) = helperPath.UTF8String;
    }
    // The profiles' contexts set no list of their own, so every Persona's pages send this one (`docs/localization.md`).
    CefString(&settings.accept_language_list) = acceptLanguageList.UTF8String;
    CefString(&settings.locale) = locale.UTF8String;
    CefRefPtr<BridgeApp> app(new BridgeApp);
    if (!CefInitialize(mainArgs, settings, app.get(), nullptr)) {
        return NO;
    }
    gInitialized = true;
    gRootCachePath = root;
    [ARCHCEFRequestContext.globalContext attachContext:CefRequestContext::GetGlobalContext()];
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

+ (BOOL)isRunningWork {
    return ARCHCEFPump.shared.isActive;
}

+ (NSString *)cefVersion {
    return @CEF_VERSION;
}

+ (void)shutdown {
    if (!gInitialized) {
        return;
    }
    gInitialized = false;
    // CEF asserts in debug builds on references the app still holds when it shuts down. Storage calls from here on change nothing, as they did before the runtime initialized, and calls still waiting for a context complete the same way.
    for (ARCHCEFRequestContext *context in gRequestContexts.allObjects) {
        [context detachContext];
    }
    ReleaseExtensionObjects();
    // CEF asks for every browser to close before it shuts down; shutting down over open browsers crashed once Chrome-style developer tools had opened. The tools in a view close first: once their browser has closed, their contents close on their own, unreported, and CEF would shut down over them. The browsers that no view shows count only with the tabs, so that one still clearing site data leaves the tabs their time to close. The closes run CEF's work for at most two seconds in all.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    for (ARCHCEFBrowser *browser in gBrowsers.allObjects) {
        if (browser.showsDevToolsInView) {
            [browser closeDevTools];
        }
    }
    [self runWorkUntil:deadline whileAnyBrowser:^BOOL(ARCHCEFBrowser *browser) { return browser.showsDevToolsInView; } orUnshownBrowser:NO];
    for (ARCHCEFBrowser *browser in gBrowsers.allObjects) {
        [browser close];
    }
    [self runWorkUntil:deadline whileAnyBrowser:^BOOL(ARCHCEFBrowser *browser) { return browser.isOpen; } orUnshownBrowser:YES];
    CefShutdown();
}

/// Runs CEF's work while any browser passes `test`, or, with `waitsForUnshown`, a browser that no view shows has not closed, until `deadline`.
+ (void)runWorkUntil:(NSDate *)deadline whileAnyBrowser:(BOOL (^)(ARCHCEFBrowser *))test orUnshownBrowser:(BOOL)waitsForUnshown {
    while (deadline.timeIntervalSinceNow > 0) {
        BOOL passes = waitsForUnshown && gUnshownBrowsers > 0;
        for (ARCHCEFBrowser *browser in gBrowsers.allObjects) {
            passes = passes || test(browser);
        }
        if (!passes) {
            return;
        }
        CefDoMessageLoopWork();
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

+ (int)runHelperWithArgc:(int)argc argv:(char **)argv {
    // The renderer, GPU, and utility processes enter the macOS sandbox before the framework loads, as CEF requires; the
    // context loads `libcef_sandbox.dylib` from the framework next to the helper bundles.
    CefScopedSandboxContext sandboxContext;
    if (!sandboxContext.Initialize(argc, argv)) {
        return 1;
    }
    CefScopedLibraryLoader libraryLoader;
    if (!libraryLoader.LoadInHelper()) {
        return 1;
    }
    CefMainArgs mainArgs(argc, argv);
    CefRefPtr<CefApp> app = MakeHelperApp();
    return CefExecuteProcess(mainArgs, app, nullptr);
}

@end
