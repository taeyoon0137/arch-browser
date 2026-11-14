// The bridge between a script plugin's documents and its context: the `arch` object that a script defines at the start of each document, the message handler that performs its calls, and the function through which the app hands the background script commands, page script values, and events. A handler belongs to one web view, so a call always acts for the plugin instance whose web view sent it, whatever the message says.
import WebKit

@MainActor
final class ScriptPluginBridge: NSObject, WKScriptMessageHandlerWithReply {
    /// The name under which documents reach the handler, `window.webkit.messageHandlers.arch`.
    static let handlerName = "arch"

    /// Defines `arch` in the document's world. Each call sends `{call, args}` as JSON text and resolves with the JSON reply parsed, or rejects with an error whose message names the failure: a `PluginError` case, or `invalidCall` for a call the handler cannot read or a value the storage cannot hold. An argument left out or `undefined` is not sent, which tells `storage.set(key)`, which removes the key, from `storage.set(key, null)`. The delivery function, `__archDeliver(kind, payload)`, runs the listener for a command or a page script value and returns the value's reply as JSON text, or null; a command without a listener throws `noListener`. It runs an event's listeners one after another and returns null once the last one settles, or JSON text that names the failure: `{"noListener": true}` when the script set none for the kind, and `{"error": text}` with what a listener threw, so that `ScriptPlugin` reads the failure without WebKit's exception details.
    static let script = #"""
    (() => {
      const handler = window.webkit.messageHandlers.arch;
      const call = async (name, args) => {
        const reply = await handler.postMessage(JSON.stringify({ call: name, args }));
        return reply == null ? undefined : JSON.parse(reply);
      };
      const given = (value) => (value === undefined ? [] : [value]);
      const commandListeners = new Map();
      const eventListeners = new Map();
      let messageListener = null;
      // What a listener threw as text: an error's message, after its name unless it is a plain Error, or the value itself.
      const describe = (thrown) => {
        try {
          if (thrown instanceof Error) return thrown.name === "Error" ? thrown.message : `${thrown.name}: ${thrown.message}`;
          return String(thrown);
        } catch {
          return "The listener threw a value that has no text.";
        }
      };
      Object.defineProperty(window, "__archDeliver", {
        value: async (kind, payload) => {
          const body = JSON.parse(payload);
          if (kind === "command") {
            const listener = commandListeners.get(body.command);
            if (!listener) throw new Error("noListener");
            await listener(body.invocation);
            return null;
          }
          if (kind === "event") {
            const listeners = eventListeners.get(body.kind) ?? [];
            if (listeners.length === 0) return JSON.stringify({ noListener: true });
            try {
              for (const listener of listeners) await listener(body.event);
            } catch (thrown) {
              return JSON.stringify({ error: describe(thrown) });
            }
            return null;
          }
          if (!messageListener) return null;
          const reply = await messageListener(body);
          return reply === undefined ? null : JSON.stringify(reply);
        },
      });
      Object.defineProperty(window, "arch", {
        value: Object.freeze({
          commands: Object.freeze({ onRun: (id, listener) => { commandListeners.set(id, listener); } }),
          events: Object.freeze({
            on: (kind, listener) => {
              if (typeof listener !== "function") throw new TypeError("arch.events.on needs a function");
              eventListeners.set(kind, [...(eventListeners.get(kind) ?? []), listener]);
            },
          }),
          tabs: Object.freeze({
            list: () => call("tabs.list", []),
            get: (id) => call("tabs.get", [id]),
            rename: (id, name) => call("tabs.rename", [id, ...given(name)]),
          }),
          pages: Object.freeze({ onMessage: (listener) => { messageListener = listener; } }),
          storage: Object.freeze({
            get: (key) => call("storage.get", [key]),
            set: (key, value) => call("storage.set", [key, ...given(value)]),
            keys: () => call("storage.keys", []),
          }),
          secrets: Object.freeze({
            get: (key) => call("secrets.get", [key]),
            set: (key, value) => call("secrets.set", [key, ...given(value)]),
          }),
          settings: Object.freeze({ get: (key) => call("settings.get", [key]) }),
          ui: Object.freeze({
            setBadge: (itemId, text) => call("ui.setBadge", [itemId, ...given(text)]),
            copy: (text) => call("ui.copy", [text]),
          }),
        }),
      });
    })();
    """#

    /// The body of the function through which the app delivers: `kind` is `command`, `message`, or `event`, and `payload` the JSON text the listener receives parsed.
    static let deliveryCall = "return await window.__archDeliver(kind, payload);"

    private let context: any PluginContext
    /// The latest secret call, which the next one waits for, so that the script's secret calls take effect in the order it made them.
    private var secretCalls: Task<Void, Never>?

    init(context: any PluginContext) {
        self.context = context
    }

    /// A secret's call waits for the Keychain off the main thread and replies once it is done, after the secret calls before it. The other calls reply before the handler returns.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let call: Call
        do {
            guard let text = message.body as? String else { throw BridgeFailure.invalidCall }
            call = try JSONDecoder().decode(Call.self, from: Data(text.utf8))
        } catch {
            return replyHandler(nil, BridgeFailure.invalidCall.rawValue)
        }
        guard call.call.hasPrefix("secrets.") else { return Self.reply(Result { try perform(call) }, to: replyHandler) }
        let previous = secretCalls
        secretCalls = Task {
            await previous?.value
            let result: Result<PluginValue?, any Error>
            do {
                result = .success(try await performSecret(call))
            } catch {
                result = .failure(error)
            }
            Self.reply(result, to: replyHandler)
        }
    }

    private static func reply(_ result: Result<PluginValue?, any Error>, to replyHandler: @MainActor @Sendable (Any?, String?) -> Void) {
        do {
            replyHandler(try result.get().map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }, nil)
        } catch let error as PluginError {
            replyHandler(nil, error.bridgeName)
        } catch {
            replyHandler(nil, BridgeFailure.invalidCall.rawValue)
        }
    }

    /// The call's result, or nil for none.
    private func perform(_ call: Call) throws -> PluginValue? {
        switch call.call {
        case "storage.get":
            return context.storage.value(forKey: try call.text(0))
        case "storage.set":
            try context.storage.setValue(call.value(1), forKey: try call.text(0))
        case "storage.keys":
            return .array(context.storage.allKeys().map(PluginValue.string))
        case "settings.get":
            return context.setting(try call.text(0))
        case "ui.setBadge":
            context.setBadge(try call.optionalText(1), onSidebarItem: try call.text(0))
        case "ui.copy":
            try context.copyToClipboard(try call.text(0))
        case "tabs.list":
            return .array(try context.tabs().map(\.scriptValue))
        case "tabs.get":
            // A tab the script does not reach is null, as is text that names no tab.
            return try UUID(uuidString: try call.text(0)).flatMap { try context.tab($0) }?.scriptValue ?? .null
        case "tabs.rename":
            guard let id = UUID(uuidString: try call.text(0)) else { throw BridgeFailure.invalidCall }
            return .bool(try context.renameTab(id, to: try call.optionalText(1)))
        default:
            throw BridgeFailure.invalidCall
        }
        return nil
    }

    /// A secret call's result, or nil for none.
    private func performSecret(_ call: Call) async throws -> PluginValue? {
        switch call.call {
        case "secrets.get":
            return try await context.secrets.secret(forKey: try call.text(0)).map(PluginValue.string)
        case "secrets.set":
            try await context.secrets.setSecret(try call.optionalText(1), forKey: try call.text(0))
            return nil
        default:
            throw BridgeFailure.invalidCall
        }
    }

    /// What the bridge script sends.
    private struct Call: Decodable {
        let call: String
        let args: [PluginValue]

        /// The argument at `index`, or nil where the script passed none.
        func value(_ index: Int) -> PluginValue? {
            args.indices.contains(index) ? args[index] : nil
        }

        func text(_ index: Int) throws -> String {
            guard case let .string(text)? = value(index) else { throw BridgeFailure.invalidCall }
            return text
        }

        /// Text, or nil where the script passed none or null.
        func optionalText(_ index: Int) throws -> String? {
            guard let value = value(index), value != .null else { return nil }
            return try text(index)
        }
    }

    private enum BridgeFailure: String, Error {
        case invalidCall
    }
}

private extension PluginError {
    /// The case's name, without its associated value.
    var bridgeName: String {
        switch self {
        case .permissionDenied: return "permissionDenied"
        case .stopped: return "stopped"
        case .noPage: return "noPage"
        case .invalidMatchPattern: return "invalidMatchPattern"
        case .invalidShortcut: return "invalidShortcut"
        case .reservedKey: return "reservedKey"
        case .quotaExceeded: return "quotaExceeded"
        case .invalidPackage: return "invalidPackage"
        case .unsupportedAPIVersion: return "unsupportedAPIVersion"
        case .timedOut: return "timedOut"
        case .invalidVersions: return "invalidVersions"
        case .closed: return "closed"
        case .notGranted: return "notGranted"
        case .noListener: return "noListener"
        case .listenerFailed: return "listenerFailed"
        }
    }
}
