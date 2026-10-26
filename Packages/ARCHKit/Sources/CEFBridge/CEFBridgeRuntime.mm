// Initializes the Chromium Embedded Framework (CEF), runs its message pump on the main run loop, and shuts it down. The helper processes start here as well.
#import "CEFBridgeInternal.h"

#include <crt_externs.h>
#include <dispatch/dispatch.h>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_command_line.h"
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

class BridgeApp : public CefApp, public CefBrowserProcessHandler {
public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    // Runs on the UI thread, which is the main thread, once the global context's profile has initialized.
    void OnContextInitialized() override {
        dispatch_async(dispatch_get_main_queue(), ^{ GlobalContextDidInitialize(); });
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

}  // namespace cef_bridge

#pragma mark - Runtime

@implementation ARCHCEFRuntime

+ (void)setAccessibilityEnabled:(BOOL)enabled {
    gAccessibilityEnabled = enabled;
    for (ARCHCEFBrowser *browser in gBrowsers) {
        [browser applyAccessibilityState];
    }
}

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
    // The helper starts no sandbox context, so the renderer, GPU, and utility processes run without the macOS sandbox (`docs/plan.md`, Decisions).
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
    gRootCachePath = cachePath.stringByStandardizingPath;
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
    // CEF asks for every browser to close before it shuts down; shutting down over open browsers crashed once Chrome-style developer tools had opened. The tools in a view close first: once their browser has closed, their contents close on their own, unreported, and CEF would shut down over them. The closes run CEF's work for at most two seconds in all.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    for (ARCHCEFBrowser *browser in gBrowsers.allObjects) {
        if (browser.showsDevToolsInView) {
            [browser closeDevTools];
        }
    }
    [self runWorkUntil:deadline whileAnyBrowser:^BOOL(ARCHCEFBrowser *browser) { return browser.showsDevToolsInView; }];
    for (ARCHCEFBrowser *browser in gBrowsers.allObjects) {
        [browser close];
    }
    [self runWorkUntil:deadline whileAnyBrowser:^BOOL(ARCHCEFBrowser *browser) { return browser.isOpen; }];
    CefShutdown();
}

/// Runs CEF's work while any browser passes `test`, until `deadline`.
+ (void)runWorkUntil:(NSDate *)deadline whileAnyBrowser:(BOOL (^)(ARCHCEFBrowser *))test {
    while (deadline.timeIntervalSinceNow > 0) {
        BOOL passes = NO;
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
    CefScopedLibraryLoader libraryLoader;
    if (!libraryLoader.LoadInHelper()) {
        return 1;
    }
    CefMainArgs mainArgs(argc, argv);
    CefRefPtr<CefApp> app = MakeHelperApp();
    return CefExecuteProcess(mainArgs, app, nullptr);
}

@end
