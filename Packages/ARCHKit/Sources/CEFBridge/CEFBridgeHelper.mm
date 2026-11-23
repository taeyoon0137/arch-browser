// Runs in the helper's renderer processes. It adds the media script and the page script channels to each document, runs each browser's page scripts, and answers the browser's requests for values only a page's script can read.
#import "CEFBridgeInternal.h"

#include <algorithm>
#include <optional>
#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_v8.h"
#include "include/cef_values.h"

using namespace cef_bridge;

namespace {

// Reports whether the document's media elements play sound, and describes the element that last played sound together with the page's Media Session metadata. It runs in the page's world before the page's scripts, so it records the page's action handlers as the page sets them and runs them for the media keys. Keep it in step with WebKitAudibleScript in the WebKit adapter.
const char kAudibleScript[] = R"JS((() => {
  const report = __archReportAudible, reportMedia = __archReportMedia, stringify = JSON.stringify, apply = Reflect.apply;
  const session = navigator.mediaSession, handlers = new Map();
  let audible = false, hidden = false, current = null, reported = "null";
  const sounds = (m) => !m.paused && !m.ended && !m.muted && m.volume > 0;
  const largest = (artwork) => {
    let best = "", area = -1;
    for (const image of artwork || []) {
      const sizes = String(image.sizes || "").toLowerCase().split(/\s+/);
      const size = sizes.includes("any") ? Infinity : Math.max(0, ...sizes.map((s) => { const [w, h] = s.split("x").map(Number); return w * h || 0; }));
      if (size > area) { area = size; best = image.src; }
    }
    return best;
  };
  const describe = () => {
    if (hidden || !current || !current.isConnected) return null;
    const metadata = session && session.metadata, duration = current.duration;
    return {
      playing: !current.paused && !current.ended, duration: Number.isFinite(duration) ? duration : 0, live: duration === Infinity,
      position: current.currentTime, rate: current.playbackRate,
      metadata: metadata && { title: metadata.title, artist: metadata.artist, album: metadata.album, artwork: largest(metadata.artwork) },
      next: handlers.has("nexttrack"), previous: handlers.has("previoustrack"),
    };
  };
  const updateMedia = () => { const text = stringify(describe()); if (text !== reported) { reported = text; reportMedia(text); } };
  const update = (event) => {
    if (event && event.target instanceof HTMLMediaElement && sounds(event.target)) current = event.target;
    const media = [...document.querySelectorAll("video, audio")];
    // When the element described last stops sounding while another still sounds, the media keys and Now Playing follow the one still sounding.
    if (!current || !current.isConnected || !sounds(current)) current = media.find(sounds) || current;
    const now = !hidden && media.some(sounds);
    if (now !== audible) { audible = now; report(now); }
    updateMedia();
  };
  for (const type of ["play", "playing", "pause", "ended", "volumechange", "emptied", "seeked", "ratechange", "durationchange", "loadedmetadata"]) document.addEventListener(type, update, true);
  addEventListener("pagehide", () => { hidden = true; update(); });
  addEventListener("pageshow", () => { hidden = false; update(); });
  if (session) {
    const prototype = Object.getPrototypeOf(session), original = prototype.setActionHandler, metadata = Object.getOwnPropertyDescriptor(prototype, "metadata");
    prototype.setActionHandler = function setActionHandler(action, handler) {
      apply(original, this, [action, handler]);
      if (this !== session) return;
      if (typeof handler === "function") handlers.set(action, handler); else handlers.delete(action);
      updateMedia();
    };
    if (metadata && metadata.set) Object.defineProperty(prototype, "metadata", { ...metadata, set(value) { apply(metadata.set, this, [value]); if (this === session) updateMedia(); } });
  }
  // The browser runs media actions through this function, which pages can call but not replace: the page's own handler, or else the media itself.
  Object.defineProperty(window, "__archMediaControl", { value: (action) => {
    const handler = handlers.get(action);
    if (handler) return void apply(handler, session, [{ action }]);
    if (action === "play" && current) current.play().catch(() => {});
    if (action === "pause") { if (current) current.pause(); for (const m of document.querySelectorAll("video, audio")) if (sounds(m)) m.pause(); }
  } });
})())JS";

// Sends a frame's audible state from its renderer to the browser, which tracks each frame.
class AudibleReporter : public CefV8Handler {
public:
    bool Execute(const CefString &name, CefRefPtr<CefV8Value> object, const CefV8ValueList &arguments, CefRefPtr<CefV8Value> &retval,
                 CefString &exception) override {
        CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
        CefRefPtr<CefFrame> frame = context ? context->GetFrame() : nullptr;
        if (arguments.size() == 1 && arguments[0]->IsBool() && frame) {
            CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kAudibleReport);
            message->GetArgumentList()->SetBool(0, arguments[0]->GetBoolValue());
            frame->SendProcessMessage(PID_BROWSER, message);
        }
        return true;
    }

private:
    IMPLEMENT_REFCOUNTING(AudibleReporter);
};

// Sends a frame's media, as the JSON text the media script writes, from its renderer to the browser.
class MediaReporter : public CefV8Handler {
public:
    bool Execute(const CefString &name, CefRefPtr<CefV8Value> object, const CefV8ValueList &arguments, CefRefPtr<CefV8Value> &retval,
                 CefString &exception) override {
        CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
        CefRefPtr<CefFrame> frame = context ? context->GetFrame() : nullptr;
        if (arguments.size() == 1 && arguments[0]->IsString() && frame) {
            CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kMediaReport);
            message->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
            frame->SendProcessMessage(PID_BROWSER, message);
        }
        return true;
    }

private:
    IMPLEMENT_REFCOUNTING(MediaReporter);
};

// Evaluates to the function that opens a world's channel in a document. That function takes the native function that sends JSON text to the browser and returns the request's number, and returns the renderer's endpoint: the `channel` the world's scripts receive, `deliver` for posted values, `reply` for replies, and `run` for the world's scripts. Endpoints live in the page's main world, so they keep what they use from the page's reach: the helper evaluates this script in each new document before the page's scripts run, so every endpoint, even one opened after the page has run, calls the built-ins as they were then, and endpoints keep their state in objects without prototypes. Keep the channel in step with `WebKitPageScripts.channelSource` in the WebKit adapter.
const char kPageScriptEndpointOpener[] = R"JS((() => {
  const stringify = JSON.stringify, parse = JSON.parse, apply = Reflect.apply, create = Object.create, freeze = Object.freeze, report = reportError;
  const PromiseType = Promise, TypeErrorType = TypeError;
  const listen = EventTarget.prototype.addEventListener, readyState = Object.getOwnPropertyDescriptor(Document.prototype, "readyState").get;
  const call = (target, args) => { try { apply(target, undefined, args); } catch (error) { report(error); } };
  return (post) => {
    const listeners = create(null), replies = create(null);
    let listenerCount = 0;
    const channel = freeze({
      send: (value) => new PromiseType((resolve) => {
        const json = stringify(value);
        if (typeof json !== "string") throw new TypeErrorType("A page script can send only values JSON can hold.");
        replies[post(json)] = resolve;
      }),
      onMessage: (listener) => {
        if (typeof listener !== "function") throw new TypeErrorType("A page script's message listener must be a function.");
        listeners[listenerCount++] = listener;
      },
    });
    return freeze({
      channel,
      deliver: (json) => { const value = parse(json); for (let i = 0; i < listenerCount; i++) call(listeners[i], [value]); },
      reply: (request, json) => {
        const resolve = replies[request];
        if (!resolve) return;
        delete replies[request];
        resolve(typeof json === "string" ? parse(json) : undefined);
      },
      run: (script, atDocumentEnd) => {
        const start = () => call(script, [channel]);
        if (atDocumentEnd && apply(readyState, document, []) === "loading") apply(listen, document, ["DOMContentLoaded", start, { once: true }]);
        else start();
      },
    });
  };
})())JS";

// One page script as a renderer keeps it.
struct PageScript {
    std::string world;
    std::string source;
    bool atDocumentEnd;
    bool mainFrameOnly;
};

std::vector<PageScript> ReadPageScripts(CefRefPtr<CefListValue> list) {
    std::vector<PageScript> scripts;
    for (size_t index = 0; list && index < list->GetSize(); index++) {
        CefRefPtr<CefDictionaryValue> entry = list->GetDictionary(index);
        scripts.push_back({entry->GetString(kPageScriptWorldKey).ToString(), entry->GetString(kPageScriptSourceKey).ToString(),
                           entry->GetBool(kPageScriptAtDocumentEndKey), entry->GetBool(kPageScriptMainFrameOnlyKey)});
    }
    return scripts;
}

// The number of the last value a page script sent from this renderer process. Numbers are never reused, so a reply that comes after its document went away cannot settle a promise of the frame's next document.
int gLastPageScriptRequest = 0;

// Sends the JSON text a page script passes to its world's channel from the renderer to the browser, and returns the request's number, which the reply carries back.
class PageScriptSender : public CefV8Handler {
public:
    explicit PageScriptSender(const std::string &world) : world_(world) {}

    bool Execute(const CefString &name, CefRefPtr<CefV8Value> object, const CefV8ValueList &arguments, CefRefPtr<CefV8Value> &retval,
                 CefString &exception) override {
        CefRefPtr<CefV8Context> context = CefV8Context::GetCurrentContext();
        CefRefPtr<CefFrame> frame = context ? context->GetFrame() : nullptr;
        if (arguments.size() != 1 || !arguments[0]->IsString() || !frame) {
            exception = "The page script channel sends only JSON text.";
            return true;
        }
        int request = ++gLastPageScriptRequest;
        CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kPageScriptSend);
        message->GetArgumentList()->SetString(0, world_);
        message->GetArgumentList()->SetInt(1, request);
        message->GetArgumentList()->SetString(2, arguments[0]->GetStringValue());
        frame->SendProcessMessage(PID_BROWSER, message);
        retval = CefV8Value::CreateInt(request);
        return true;
    }

private:
    std::string world_;
    IMPLEMENT_REFCOUNTING(PageScriptSender);
};

// Evaluates `code` in the context the caller entered. Returns its value, or nullptr when it throws.
CefRefPtr<CefV8Value> Evaluate(CefRefPtr<CefV8Context> context, const CefString &code) {
    CefRefPtr<CefV8Value> value;
    CefRefPtr<CefV8Exception> exception;
    return context->Eval(code, CefString(), 0, value, exception) ? value : nullptr;
}

// Evaluates a function expression in the context the caller entered. Returns the function, or nullptr when the text is not one.
CefRefPtr<CefV8Value> EvaluateFunction(CefRefPtr<CefV8Context> context, const std::string &function) {
    // On lines of their own, the brackets make any function expression evaluate to its function, and a final line comment in it cannot hide them.
    CefRefPtr<CefV8Value> value = Evaluate(context, "(\n" + function + "\n)");
    return value && value->IsFunction() ? value : nullptr;
}

// Evaluates `script` in the frame's page world. Returns the string it evaluates to, or nothing when the frame has no script context or the script throws or returns another type.
std::optional<CefString> EvaluateString(CefRefPtr<CefFrame> frame, const CefString &script) {
    CefRefPtr<CefV8Context> context = frame->GetV8Context();
    if (!context || !context->Enter()) {
        return std::nullopt;
    }
    std::optional<CefString> result;
    if (CefRefPtr<CefV8Value> value = Evaluate(context, script); value && value->IsString()) {
        result = value->GetStringValue();
    }
    context->Exit();
    return result;
}

// Whether `context` is the page's main world context of the frame's document.
bool IsMainWorld(CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context) {
    CefRefPtr<CefV8Context> main = frame->GetV8Context();
    return main && main->IsSame(context);
}

// Calls the function a world's endpoint holds under `name`, in the context the caller entered.
void CallEndpoint(CefRefPtr<CefV8Value> endpoint, const char *name, const CefV8ValueList &arguments) {
    CefRefPtr<CefV8Value> function = endpoint->GetValue(name);
    if (function && function->IsFunction()) {
        function->ExecuteFunction(nullptr, arguments);
    }
}

// Runs in the helper's renderer processes. It answers the browser's requests for values only a page's script can read, and runs each browser's page scripts with their worlds' channels.
class HelperApp : public CefApp, public CefRenderProcessHandler {
public:
    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

    void OnBrowserCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDictionaryValue> extra_info) override {
        if (extra_info && extra_info->HasKey(kPageScriptsKey)) {
            SetPageScripts(browser, ReadPageScripts(extra_info->GetList(kPageScriptsKey)));
        }
    }

    void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
        std::erase_if(pageScripts_, [&](const BrowserScripts &entry) { return entry.browser->IsSame(browser); });
    }

    // Every frame's document reports its audible state and its media, through functions pages can call but not replace. Then the document gets its opener of page script endpoints, and the page scripts run, before the page's own scripts.
    // CEF calls this for the context of every world, also the extensions' content script worlds and the worlds DevTools makes, so only the page's main world gets the media script and the page scripts.
    void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context) override {
        if (!IsMainWorld(frame, context) || !context->Enter()) {
            return;
        }
        context->GetGlobal()->SetValue("__archReportAudible", CefV8Value::CreateFunction("__archReportAudible", new AudibleReporter()),
                                       static_cast<cef_v8_propertyattribute_t>(V8_PROPERTY_ATTRIBUTE_READONLY | V8_PROPERTY_ATTRIBUTE_DONTENUM |
                                                                               V8_PROPERTY_ATTRIBUTE_DONTDELETE));
        context->GetGlobal()->SetValue("__archReportMedia", CefV8Value::CreateFunction("__archReportMedia", new MediaReporter()),
                                       static_cast<cef_v8_propertyattribute_t>(V8_PROPERTY_ATTRIBUTE_READONLY | V8_PROPERTY_ATTRIBUTE_DONTENUM |
                                                                               V8_PROPERTY_ATTRIBUTE_DONTDELETE));
        Evaluate(context, kAudibleScript);
        if (CefRefPtr<CefV8Value> open = Evaluate(context, kPageScriptEndpointOpener); open && open->IsFunction()) {
            openers_.push_back({context, open});
        }
        RunPageScripts(browser, frame, context);
        context->Exit();
    }

    void OnContextReleased(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context) override {
        std::erase_if(openers_, [&](const EndpointOpener &opener) { return opener.context->IsSame(context); });
        std::erase_if(endpoints_, [&](const WorldEndpoint &endpoint) { return endpoint.context->IsSame(context); });
    }

    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefProcessId sourceProcess,
                                  CefRefPtr<CefProcessMessage> message) override {
        CefRefPtr<CefListValue> arguments = message->GetArgumentList();
        if (message->GetName() == kScriptRequest) {
            // A request with a world calls a function with that world's channel; one without evaluates a script, for which a value other than a string counts as a failure.
            std::optional<CefString> result;
            bool succeeded;
            if (arguments->GetType(2) == VTYPE_STRING) {
                succeeded = CallWithChannel(frame, arguments->GetString(2).ToString(), arguments->GetString(1).ToString(), result);
            } else {
                result = EvaluateString(frame, arguments->GetString(1));
                succeeded = result.has_value();
            }
            CefRefPtr<CefProcessMessage> reply = CefProcessMessage::Create(kScriptReply);
            reply->GetArgumentList()->SetInt(0, arguments->GetInt(0));
            reply->GetArgumentList()->SetBool(1, succeeded);
            if (result) {
                reply->GetArgumentList()->SetString(2, *result);
            } else {
                reply->GetArgumentList()->SetNull(2);
            }
            frame->SendProcessMessage(PID_BROWSER, reply);
            return true;
        }
        if (message->GetName() == kPageScriptsUpdate) {
            SetPageScripts(browser, ReadPageScripts(arguments->GetList(0)));
            return true;
        }
        if (message->GetName() == kPageScriptReply) {
            Deliver(frame, arguments->GetString(0).ToString(), "reply", [&] {
                CefRefPtr<CefV8Value> json = arguments->GetType(2) == VTYPE_STRING ? CefV8Value::CreateString(arguments->GetString(2)) : CefV8Value::CreateNull();
                return CefV8ValueList{CefV8Value::CreateInt(arguments->GetInt(1)), json};
            });
            return true;
        }
        if (message->GetName() == kPageScriptDelivery) {
            Deliver(frame, arguments->GetString(0).ToString(), "deliver", [&] { return CefV8ValueList{CefV8Value::CreateString(arguments->GetString(1))}; });
            return true;
        }
        return false;
    }

private:
    // The page scripts of one browser in this process. During a cross-origin navigation, CEF can create a browser object before it destroys the old one with the same identifier, so the scripts belong to the object.
    struct BrowserScripts {
        CefRefPtr<CefBrowser> browser;
        std::vector<PageScript> scripts;
    };

    // The function that opens world endpoints in one document, made before the page's scripts ran.
    struct EndpointOpener {
        CefRefPtr<CefV8Context> context;
        CefRefPtr<CefV8Value> open;
    };

    // A world's endpoint in one document.
    struct WorldEndpoint {
        std::string world;
        CefRefPtr<CefV8Context> context;
        CefRefPtr<CefV8Value> endpoint;
    };

    void SetPageScripts(CefRefPtr<CefBrowser> browser, std::vector<PageScript> scripts) {
        for (BrowserScripts &entry : pageScripts_) {
            if (entry.browser->IsSame(browser)) {
                entry.scripts = std::move(scripts);
                return;
            }
        }
        pageScripts_.push_back({browser, std::move(scripts)});
    }

    // Runs the browser's page scripts that apply to the frame in its new document, in the context the caller entered. A script can run code that creates another frame's context and runs these again, so the loop goes over its own copy.
    void RunPageScripts(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context) {
        auto found = std::find_if(pageScripts_.begin(), pageScripts_.end(), [&](const BrowserScripts &entry) { return entry.browser->IsSame(browser); });
        if (found == pageScripts_.end()) {
            return;
        }
        const std::vector<PageScript> scripts = found->scripts;
        for (const PageScript &script : scripts) {
            if (script.mainFrameOnly && !frame->IsMain()) {
                continue;
            }
            CefRefPtr<CefV8Value> endpoint = OpenEndpoint(context, script.world);
            CefRefPtr<CefV8Value> function = EvaluateFunction(context, script.source);
            if (endpoint && function) {
                CallEndpoint(endpoint, "run", {function, CefV8Value::CreateBool(script.atDocumentEnd)});
            }
        }
    }

    // The world's endpoint in the document of `context`, or nullptr when the document has none.
    CefRefPtr<CefV8Value> FindEndpoint(CefRefPtr<CefV8Context> context, const std::string &world) {
        for (const WorldEndpoint &endpoint : endpoints_) {
            if (endpoint.world == world && endpoint.context->IsSame(context)) {
                return endpoint.endpoint;
            }
        }
        return nullptr;
    }

    // The world's endpoint in the document of `context`, which the caller entered, opened there with the document's opener if the document has none. nullptr when the document has no opener or the opener fails.
    CefRefPtr<CefV8Value> OpenEndpoint(CefRefPtr<CefV8Context> context, const std::string &world) {
        if (CefRefPtr<CefV8Value> endpoint = FindEndpoint(context, world)) {
            return endpoint;
        }
        auto opener = std::find_if(openers_.begin(), openers_.end(), [&](const EndpointOpener &entry) { return entry.context->IsSame(context); });
        if (opener == openers_.end()) {
            return nullptr;
        }
        CefRefPtr<CefV8Value> endpoint = opener->open->ExecuteFunction(nullptr, {CefV8Value::CreateFunction("send", new PageScriptSender(world))});
        if (!endpoint || !endpoint->IsObject()) {
            return nullptr;
        }
        endpoints_.push_back({world, context, endpoint});
        return endpoint;
    }

    // Calls `function`, a function expression, with the world's channel in the frame's current document. Returns whether it ran without throwing, with the string it returned in `result`.
    bool CallWithChannel(CefRefPtr<CefFrame> frame, const std::string &world, const std::string &function, std::optional<CefString> &result) {
        CefRefPtr<CefV8Context> context = frame->GetV8Context();
        if (!context || !context->Enter()) {
            return false;
        }
        CefRefPtr<CefV8Value> endpoint = OpenEndpoint(context, world);
        CefRefPtr<CefV8Value> callee = EvaluateFunction(context, function);
        CefRefPtr<CefV8Value> value = endpoint && callee ? callee->ExecuteFunction(nullptr, {endpoint->GetValue("channel")}) : nullptr;
        if (value && value->IsString()) {
            result = value->GetStringValue();
        }
        context->Exit();
        return value != nullptr;
    }

    // Calls a function of the world's endpoint in the frame's current document with the arguments `makeArguments` creates there. Nothing happens when the document has no endpoint for the world.
    template <typename MakeArguments>
    void Deliver(CefRefPtr<CefFrame> frame, const std::string &world, const char *name, MakeArguments makeArguments) {
        CefRefPtr<CefV8Context> context = frame->GetV8Context();
        if (!context || !context->Enter()) {
            return;
        }
        if (CefRefPtr<CefV8Value> endpoint = FindEndpoint(context, world)) {
            CallEndpoint(endpoint, name, makeArguments());
        }
        context->Exit();
    }

    std::vector<BrowserScripts> pageScripts_;
    // The endpoint openers and endpoints of the documents in this process, removed as their contexts go.
    std::vector<EndpointOpener> openers_;
    std::vector<WorldEndpoint> endpoints_;
    IMPLEMENT_REFCOUNTING(HelperApp);
};

}  // namespace

CefRefPtr<CefApp> cef_bridge::MakeHelperApp() {
    return new HelperApp();
}
