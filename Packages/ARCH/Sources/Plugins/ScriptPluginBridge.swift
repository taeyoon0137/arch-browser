// This bridge defines `arch` in each script plugin document and handles its calls.
// It also delivers commands, page script values, and events to the background script.
// A handler belongs to one web view. Its calls act for that view's plugin instance, regardless of the message contents.
// A panel receives `arch` without listeners or page calls. Only the background script receives deliveries and makes page calls.
import AI
import ARCHEngine
import WebKit

@MainActor
final class ScriptPluginBridge: NSObject, WKScriptMessageHandlerWithReply {
    /// The name under which documents reach the handler, `window.webkit.messageHandlers.arch`.
    static let handlerName = "arch"

    /// The document that the bridge serves.
    enum Role {
        /// The background script's, which sets the listeners.
        case background
        /// A panel's, whose AI requests and renames the user makes there, so they belong to no hook step of the plugin.
        case panel
    }

    /// Defines `arch` in the document's world. Each call sends `{call, args}` as JSON text and resolves with the JSON reply parsed, or rejects with an error whose message names the failure: a `PluginError` or `AIError` case, or `invalidCall` for a call the handler cannot read or a value the storage cannot hold. An argument left out or `undefined` is not sent, which tells `storage.set(key)`, which removes the key, from `storage.set(key, null)`. `ai.stream(request, onText)` asks for the reply's text with `ai.next` until the reply ends, waits for `onText` with each piece, and resolves as `ai.reply` does; when `onText` throws, it stops the request with `ai.cancel` and rejects with what `onText` threw. In the background document, the delivery function, `__archDeliver(kind, payload)`, runs the listener for a command or a page script value and returns the value's reply as JSON text, or null; a command without a listener throws `noListener`. It runs an event's listeners one after another and returns null once the last one settles, or JSON text that names the failure: `{"noListener": true}` when the script set none for the kind, and `{"error": text}` with what a listener threw, so that `ScriptPlugin` reads the failure without WebKit's exception details.
    var script: String {
        let permitsAgent = (context as? any PluginAgentContext)?.permitsAgentRuns == true
        let listens = role == .background
        return #"""
    (() => {
      const handler = window.webkit.messageHandlers.arch;
      const call = async (name, args) => {
        const reply = await handler.postMessage(JSON.stringify({ call: name, args }));
        return reply == null ? undefined : JSON.parse(reply);
      };
      const given = (value) => (value === undefined ? [] : [value]);
      const stream = async (request, onText) => {
        if (typeof onText !== "function") throw new Error("invalidCall");
        const id = await call("ai.stream", [request]);
        let text = "";
        for (;;) {
          const next = await call("ai.next", [id]);
          if (next.finishReason !== undefined) return { text, finishReason: next.finishReason };
          text += next.text;
          try {
            await onText(next.text);
          } catch (thrown) {
            call("ai.cancel", [id]).catch(() => {});
            throw thrown;
          }
        }
      };
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
      if (\#(listens)) {
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
      }
      Object.defineProperty(window, "arch", {
        value: Object.freeze({
          ...(\#(permitsAgent) ? { agent: Object.freeze({ run: (options) => call("agent.run", [options]) }) } : {}),
          ai: Object.freeze({ reply: (request) => call("ai.reply", [request]), stream }),
          net: Object.freeze({ fetch: (url, options) => call("net.fetch", [url, ...given(options)]) }),
          ...(\#(listens) ? {
            commands: Object.freeze({ onRun: (id, listener) => { commandListeners.set(id, listener); } }),
            events: Object.freeze({
              on: (kind, listener) => {
                if (typeof listener !== "function") throw new TypeError("arch.events.on needs a function");
                eventListeners.set(kind, [...(eventListeners.get(kind) ?? []), listener]);
              },
            }),
            pages: Object.freeze({
              run: (tabId, file) => call("pages.run", [tabId, file]),
              post: (tabId, message) => call("pages.post", [tabId, message === undefined ? null : message]),
              onMessage: (listener) => { messageListener = listener; },
            }),
          } : {}),
          tabs: Object.freeze({
            list: () => call("tabs.list", []),
            get: (id) => call("tabs.get", [id]),
            selected: () => call("tabs.selected", []),
            open: (url, options) => call("tabs.open", [url, ...given(options)]),
            close: (id) => call("tabs.close", [id]),
            select: (id) => call("tabs.select", [id]),
            move: (id, place) => call("tabs.move", [id, ...given(place)]),
            pin: (id) => call("tabs.pin", [id]),
            unpin: (id) => call("tabs.unpin", [id]),
            rename: (id, name) => call("tabs.rename", [id, ...given(name)]),
          }),
          downloads: Object.freeze({
            list: () => call("downloads.list", []),
            rename: (id, name) => call("downloads.rename", [id, name]),
          }),
          history: Object.freeze({ search: (text, limit) => call("history.search", [text, ...given(limit)]) }),
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
            setEnabled: (commandId, flag) => call("ui.setEnabled", [commandId, flag]),
            showPanel: (itemId) => call("ui.showPanel", [itemId]),
            notify: (title, body) => call("ui.notify", [title, body]),
            copy: (text) => call("ui.copy", [text]),
          }),
        }),
      });
    })();
    """#
    }

    /// The body of the function through which the app delivers: `kind` is `command`, `message`, or `event`, and `payload` the JSON text the listener receives parsed.
    static let deliveryCall = "return await window.__archDeliver(kind, payload);"

    private let context: any PluginContext
    private let role: Role
    /// The latest secret call, which the next one waits for, so that the script's secret calls take effect in the order it made them.
    private var secretCalls: Task<Void, Never>?
    /// Told true as a call that the plugin's context and the bridge accepted starts to wait for Arch's own answer, an AI request's reply or its next text, or a page call's run in the tab's page, and false as it ends, so that the instance does not count that wait toward its hang limit.
    var waitsForArch: ((Bool) -> Void)?
    /// The `arch.ai.reply` requests that have not ended and the `arch.ai.stream` replies that the script has not read to their end, by number, which `end()` stops.
    private var replies: [Int: Task<Void, Never>] = [:]
    private var streams: [Int: AIReplyStream] = [:]
    private var nextRequestNumber = 0
    /// Set once the document's web view goes, after which every call fails with `stopped`.
    private var hasEnded = false

    init(context: any PluginContext, role: Role = .background) {
        self.context = context
        self.role = role
    }

    /// Stops the AI requests of the document's calls, as its panel closes or its instance stops, and fails its later calls with `stopped`.
    func end() {
        hasEnded = true
        for task in replies.values { task.cancel() }
        replies = [:]
        let ended = streams.values
        streams = [:]
        for stream in ended {
            stream.task?.cancel()
            if let waiting = stream.waiting {
                waitsForArch?(false)
                Self.reply(.failure(PluginError.stopped), to: waiting)
            }
        }
    }

    /// A secret's call waits for the Keychain off the main thread and replies once it is done, after the secret calls before it, an AI reply's call once its reply has come, a stream's `ai.next` call once text arrives or the reply ends, `pages.run` once the page has run the script, and `history.search` once the history store has read the pages. The other calls reply before the handler returns.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard !hasEnded else { return replyHandler(nil, PluginError.stopped.bridgeName) }
        let call: Call
        do {
            guard let text = message.body as? String else { throw BridgeFailure.invalidCall }
            call = try JSONDecoder().decode(Call.self, from: Data(text.utf8))
        } catch {
            return replyHandler(nil, BridgeFailure.invalidCall.rawValue)
        }
        switch call.call {
        case "agent.run":
            guard let agent = context as? any PluginAgentContext, agent.permitsAgentRuns, call.args.count == 1,
                  let options = call.value(0) else { return replyHandler(nil, "permissionDenied") }
            Task {
                do { Self.reply(.success(try await agent.runAgent(options)), to: replyHandler) }
                catch { Self.reply(.failure(error), to: replyHandler) }
            }
        case "ai.reply", "ai.stream":
            // The client belongs to the hook step that runs as the call arrives, unless a panel makes it. A call refused here does not wait for Arch.
            let client: any AIClient
            let request: AIRequest
            do {
                client = try aiClient()
                request = try aiRequest(of: call)
            } catch {
                return Self.reply(.failure(error), to: replyHandler)
            }
            if call.call == "ai.stream" { return Self.reply(.success(startStream(request, with: client)), to: replyHandler) }
            let number = nextRequestNumber
            nextRequestNumber += 1
            waitsForArch?(true)
            replies[number] = Task {
                defer {
                    waitsForArch?(false)
                    replies[number] = nil
                }
                do { Self.reply(.success(Self.value(of: try await client.reply(request))), to: replyHandler) }
                catch { Self.reply(.failure(error), to: replyHandler) }
            }
        case "net.fetch":
            let request: URLRequest
            do { request = try networkRequest(of: call) }
            catch { return Self.reply(.failure(error), to: replyHandler) }
            let number = nextRequestNumber
            nextRequestNumber += 1
            waitsForArch?(true)
            replies[number] = Task {
                defer {
                    waitsForArch?(false)
                    replies[number] = nil
                }
                do {
                    let (data, response) = try await context.fetch(request)
                    guard !hasEnded else { throw PluginError.stopped }
                    guard let text = String(data: data, encoding: .utf8) else { throw PluginError.invalidResponse }
                    var headers: [String: PluginValue] = [:]
                    for (key, value) in response.allHeaderFields {
                        if let key = key as? String, let value = value as? String { headers[key] = .string(value) }
                    }
                    Self.reply(.success(.object(["status": .number(Double(response.statusCode)), "headers": .object(headers), "text": .string(text)])), to: replyHandler)
                } catch { Self.reply(.failure(error), to: replyHandler) }
            }
        case "pages.run":
            // A panel's `arch` has no `pages`, so a panel's document cannot make the call by posting to the handler itself either.
            guard role == .background, call.args.count == 2, let tabID = try? call.text(0), let id = UUID(uuidString: tabID),
                  let file = try? call.text(1) else { return replyHandler(nil, BridgeFailure.invalidCall.rawValue) }
            waitsForArch?(true)
            Task {
                defer { waitsForArch?(false) }
                do { Self.reply(.success(try await context.runPageScript(.file(file), in: id)), to: replyHandler) }
                catch { Self.reply(.failure(error), to: replyHandler) }
            }
        case "history.search":
            // `{url, title, lastVisit, visitCount}` for each page. The limit is a whole number from 1, of which the context gives at most `PluginManager.historyLimit`, as it does without one or with null.
            let text: String
            let limit: Int
            do {
                guard call.args.count <= 2 else { throw BridgeFailure.invalidCall }
                text = try call.text(0)
                limit = call.value(1) == nil || call.value(1) == .null ? PluginManager.historyLimit : try call.wholeNumber(1)
                guard limit >= 1 else { throw BridgeFailure.invalidCall }
            } catch {
                return replyHandler(nil, BridgeFailure.invalidCall.rawValue)
            }
            waitsForArch?(true)
            Task {
                defer { waitsForArch?(false) }
                do { Self.reply(.success(.array(try await context.history(matching: text, limit: limit).map(\.scriptValue))), to: replyHandler) }
                catch { Self.reply(.failure(error), to: replyHandler) }
            }
        case "ai.next":
            guard let number = try? call.wholeNumber(0), let stream = streams[number], stream.waiting == nil else { return replyHandler(nil, BridgeFailure.invalidCall.rawValue) }
            if let piece = takePiece(of: number) { return Self.reply(piece, to: replyHandler) }
            stream.waiting = replyHandler
            waitsForArch?(true)
        case "ai.cancel":
            guard let number = try? call.wholeNumber(0) else { return replyHandler(nil, BridgeFailure.invalidCall.rawValue) }
            if let stream = streams.removeValue(forKey: number) {
                stream.task?.cancel()
                if let waiting = stream.waiting {
                    waitsForArch?(false)
                    Self.reply(.failure(AIError.cancelled), to: waiting)
                }
            }
            replyHandler(nil, nil)
        case let name where name.hasPrefix("secrets."):
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
        default:
            Self.reply(Result { try perform(call) }, to: replyHandler)
        }
    }

    /// The AI interface for a call of the document: a panel's belongs to no hook step of the plugin.
    private func aiClient() throws -> any AIClient {
        if role == .panel, let context = context as? any PluginPanelContext { return try context.panelAI() }
        return try context.ai()
    }

    /// Renames the tab for a call of the document: a panel's rename belongs to no hook step of the plugin.
    private func renameTab(_ id: PluginTab.ID, to name: String?) throws -> Bool {
        if role == .panel, let context = context as? any PluginPanelContext { return try context.panelRenameTab(id, to: name) }
        return try context.renameTab(id, to: name)
    }

    /// Closes or selects the tab for a call of the document: a panel's call belongs to no hook step of the plugin.
    private func manageTab(_ id: PluginTab.ID, closing: Bool) throws {
        if role == .panel, let context = context as? any PluginPanelContext {
            if closing { try context.panelCloseTab(id) } else { try context.panelSelectTab(id) }
        } else if closing {
            try context.closeTab(id)
        } else {
            try context.selectTab(id)
        }
    }

    /// Moves the tab for a call of the document: a panel's move belongs to no hook step of the plugin.
    private func moveTab(_ id: PluginTab.ID, to place: PluginTabPlace) throws -> Bool {
        if role == .panel, let context = context as? any PluginPanelContext { return try context.panelMoveTab(id, to: place) }
        return try context.moveTab(id, to: place)
    }

    /// Pins or unpins the tab for a call of the document: a panel's call belongs to no hook step of the plugin.
    private func setPinned(_ isPinned: Bool, tab id: PluginTab.ID) throws -> Bool {
        if role == .panel, let context = context as? any PluginPanelContext { return try context.panelSetPinned(isPinned, tab: id) }
        return try context.setPinned(isPinned, tab: id)
    }

    /// Starts reading the reply of an `arch.ai.stream` call and returns the stream's number, with which the script asks for its text.
    private func startStream(_ request: AIRequest, with client: any AIClient) -> PluginValue {
        let number = nextRequestNumber
        nextRequestNumber += 1
        let stream = AIReplyStream()
        streams[number] = stream
        stream.task = Task { [weak self] in
            let end = await Self.read(client.stream(request), output: request.output) { [weak self] text in
                guard let self, let stream = streams[number] else { return }
                stream.text += text
                answer(number)
            }
            guard let self, let stream = streams[number] else { return }
            stream.end = end
            answer(number)
        }
        return .number(Double(number))
    }

    /// Answers the stream's waiting `ai.next` call once there is something to say.
    private func answer(_ number: Int) {
        guard let stream = streams[number], let waiting = stream.waiting, let piece = takePiece(of: number) else { return }
        stream.waiting = nil
        waitsForArch?(false)
        Self.reply(piece, to: waiting)
    }

    /// What the stream's next `ai.next` call resolves with: `{text}` with the text that arrived since the last one, or once the script has read all of it and the reply has ended, `{finishReason}`, or the error it ended with, after which the stream goes. Nil while neither has come.
    private func takePiece(of number: Int) -> Result<PluginValue?, any Error>? {
        guard let stream = streams[number] else { return nil }
        if !stream.text.isEmpty {
            defer { stream.text = "" }
            return .success(.object(["text": .string(stream.text)]))
        }
        guard let end = stream.end else { return nil }
        streams[number] = nil
        return end.map { .object(["finishReason": .string(Self.name(of: $0))]) }
    }

    /// Reads a reply, handing on each piece of text as it arrives, and returns how it ended, by the rules of `AIClient.reply(_:)`: a reply that ends without finishing is malformed, and a JSON reply must parse.
    static func read(_ events: AsyncThrowingStream<AIEvent, any Error>, output: AIOutputFormat, receive: (String) -> Void) async -> Result<AIFinishReason, any Error> {
        var text = ""
        var hasStarted = false
        var finishReason: AIFinishReason?
        do {
            for try await event in events {
                switch event {
                case .started: hasStarted = true
                case let .text(delta) where !delta.isEmpty:
                    text += delta
                    receive(delta)
                case let .finished(reason): finishReason = reason
                case .waiting, .text, .toolCall, .usage: break
                }
            }
            // A stream read by a canceled task ends without an error.
            if Task.isCancelled { throw AIError.cancelled }
            guard hasStarted, let finishReason else { throw AIError.malformedReply("The reply ended without finishing.") }
            if case .json = output, (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)) == nil {
                throw finishReason == .lengthLimit ? AIError.replyTooLong : AIError.malformedReply("The reply is not valid JSON.")
            }
            return .success(finishReason)
        } catch {
            return .failure(error)
        }
    }

    private static func reply(_ result: Result<PluginValue?, any Error>, to replyHandler: @MainActor @Sendable (Any?, String?) -> Void) {
        do {
            replyHandler(try result.get().map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }, nil)
        } catch let error as PluginError {
            replyHandler(nil, error.bridgeName)
        } catch let error as AIError {
            replyHandler(nil, error.bridgeName)
        } catch {
            replyHandler(nil, BridgeFailure.invalidCall.rawValue)
        }
    }

    /// The request of `arch.ai.reply(request)`, which sends `{instructions, messages, schema, maxOutputTokens}`, where each message is `{role, text}` or `{role, parts}` with the role `user` or `assistant`, `schema` a JSON Schema object for a JSON reply, and only `messages` required. The plugin's context checks the grant first, and its AI client the parts' kinds.
    private func aiRequest(of call: Call) throws -> AIRequest {
        guard call.args.count == 1, case .object(var fields)? = call.value(0) else { throw BridgeFailure.invalidCall }
        var instructions: String?
        if let value = fields.removeValue(forKey: "instructions"), value != .null {
            guard case let .string(text) = value else { throw BridgeFailure.invalidCall }
            instructions = text
        }
        guard case let .array(items)? = fields.removeValue(forKey: "messages"), !items.isEmpty else { throw BridgeFailure.invalidCall }
        let messages = try items.map { item -> AIMessage in
            guard case let .object(message) = item, message.count == 2, case let .string(name)? = message["role"], let role = AIMessage.Role(rawValue: name) else {
                throw BridgeFailure.invalidCall
            }
            switch (message["text"], message["parts"]) {
            case let (.string(text)?, nil): return AIMessage(role: role, parts: [.text(text)])
            case let (nil, .array(parts)?) where !parts.isEmpty: return AIMessage(role: role, parts: try parts.map(Self.part))
            default: throw BridgeFailure.invalidCall
            }
        }
        var output = AIOutputFormat.text
        if let schema = fields.removeValue(forKey: "schema"), schema != .null {
            guard case .object = schema else { throw BridgeFailure.invalidCall }
            output = .json(schema: try JSONEncoder().encode(schema))
        }
        var maxOutputTokens: Int?
        if let value = fields.removeValue(forKey: "maxOutputTokens"), value != .null {
            guard case let .number(number) = value, number >= 1, number <= Double(Int32.max), number == number.rounded() else { throw BridgeFailure.invalidCall }
            maxOutputTokens = Int(number)
        }
        // A key the bridge does not read, such as a model, would go without effect.
        guard fields.isEmpty else { throw BridgeFailure.invalidCall }
        return AIRequest(feature: .plugin(context.pluginID.rawValue), instructions: instructions, messages: messages, output: output, maxOutputTokens: maxOutputTokens)
    }

    private func networkRequest(of call: Call) throws -> URLRequest {
        guard (1...2).contains(call.args.count), let url = URL(string: try call.text(0)) else { throw BridgeFailure.invalidCall }
        var request = URLRequest(url: url)
        guard call.args.count == 2 else { return request }
        guard case .object(var fields)? = call.value(1) else { throw BridgeFailure.invalidCall }
        if let method = fields.removeValue(forKey: "method") {
            guard case let .string(name) = method, ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(name) else { throw PluginError.invalidRequest }
            request.httpMethod = name
        }
        if let headers = fields.removeValue(forKey: "headers") {
            guard case let .object(values) = headers else { throw PluginError.invalidRequest }
            for (name, value) in values {
                guard case let .string(text) = value, PluginNetworkFetch.isAllowedHeader(name: name, value: text) else { throw PluginError.invalidRequest }
                request.setValue(text, forHTTPHeaderField: name)
            }
        }
        if let body = fields.removeValue(forKey: "body") {
            guard case let .string(text) = body, text.utf8.count <= PluginNetworkFetch.requestLimit else { throw PluginError.invalidRequest }
            request.httpBody = Data(text.utf8)
        }
        guard fields.isEmpty else { throw BridgeFailure.invalidCall }
        try PluginNetworkFetch.validate(request)
        return request
    }

    /// A message's part: `{type: "text", text}`, or `{type: "page", url, title, text}` and `{type: "selection", url, title, text}` with the page's address and title, which the plugin's `ai` permission must list.
    private static func part(_ value: PluginValue) throws -> AIPart {
        guard case let .object(fields) = value, case let .string(type)? = fields["type"], case let .string(text)? = fields["text"] else { throw BridgeFailure.invalidCall }
        if type == "text", fields.count == 2 { return .text(text) }
        guard type == "page" || type == "selection", fields.count == 4, case let .string(address)? = fields["url"], let url = URL(string: address), url.scheme != nil,
              case let .string(title)? = fields["title"] else { throw BridgeFailure.invalidCall }
        return type == "page" ? .page(AIPageContent(url: url, title: title, text: text)) : .selection(AISelection(pageURL: url, pageTitle: title, text: text))
    }

    /// What `arch.ai.reply` resolves with: `{text, finishReason}`.
    private static func value(of reply: AIReply) -> PluginValue {
        .object(["text": .string(reply.text), "finishReason": .string(name(of: reply.finishReason))])
    }

    /// A finish reason as scripts read it: `completed` or `lengthLimit`.
    private static func name(of reason: AIFinishReason) -> String {
        reason == .lengthLimit ? "lengthLimit" : "completed"
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
        case "ui.setEnabled":
            context.setEnabled(try call.bool(1), command: try call.text(0))
        case "ui.showPanel":
            // A command reaches only the background script, so a panel's or settings page's call never comes from the user's command.
            guard role == .background else { break }
            context.showPanel(try call.text(0))
        case "ui.notify":
            try context.notify(title: try call.text(0), body: try call.text(1))
        case "ui.copy":
            try context.copyToClipboard(try call.text(0))
        case "tabs.list":
            return .array(try context.tabs().map(\.scriptValue))
        case "downloads.list":
            return .array(try context.downloads().map(\.scriptValue))
        case "downloads.rename":
            guard call.args.count == 2, let id = UUID(uuidString: try call.text(0)) else { throw BridgeFailure.invalidCall }
            return .bool(try context.renameDownload(id, to: try call.text(1)))
        case "tabs.get":
            // A tab the script does not reach is null, as is text that names no tab.
            return try UUID(uuidString: try call.text(0)).flatMap { try context.tab($0) }?.scriptValue ?? .null
        case "tabs.selected":
            return try context.selectedTab()?.scriptValue ?? .null
        case "tabs.open":
            guard call.args.count <= 2, let url = URL(string: try call.text(0)), url.scheme != nil else { throw BridgeFailure.invalidCall }
            return .string(try context.openTab(url, try Self.openTabOptions(call.value(1))).uuidString)
        case "tabs.close", "tabs.select":
            guard call.args.count == 1, let id = UUID(uuidString: try call.text(0)) else { throw BridgeFailure.invalidCall }
            try manageTab(id, closing: call.call == "tabs.close")
        case "tabs.move":
            guard call.args.count <= 2, let id = UUID(uuidString: try call.text(0)) else { throw BridgeFailure.invalidCall }
            return .bool(try moveTab(id, to: try Self.tabPlace(call.value(1))))
        case "tabs.pin", "tabs.unpin":
            guard call.args.count == 1, let id = UUID(uuidString: try call.text(0)) else { throw BridgeFailure.invalidCall }
            return .bool(try setPinned(call.call == "tabs.pin", tab: id))
        case "tabs.rename":
            guard let id = UUID(uuidString: try call.text(0)) else { throw BridgeFailure.invalidCall }
            return .bool(try renameTab(id, to: try call.optionalText(1)))
        case "pages.post":
            guard role == .background, call.args.count == 2, let id = UUID(uuidString: try call.text(0)), let message = call.value(1) else { throw BridgeFailure.invalidCall }
            try context.postMessage(message, toTab: id)
        default:
            throw BridgeFailure.invalidCall
        }
        return nil
    }

    /// The options of `arch.tabs.open(url, options)`: `{spaceId, select, engine}`, each optional, with the engine named as tab objects name it, `webKit` or `chromium`. A missing or null value takes the default.
    private static func openTabOptions(_ value: PluginValue?) throws -> PluginOpenTabOptions {
        guard let value, value != .null else { return PluginOpenTabOptions() }
        guard case var .object(fields) = value else { throw BridgeFailure.invalidCall }
        var options = PluginOpenTabOptions()
        if let space = fields.removeValue(forKey: "spaceId"), space != .null {
            guard case let .string(text) = space, let id = UUID(uuidString: text) else { throw BridgeFailure.invalidCall }
            options.spaceID = id
        }
        if let select = fields.removeValue(forKey: "select"), select != .null {
            guard case let .bool(flag) = select else { throw BridgeFailure.invalidCall }
            options.select = flag
        }
        if let engine = fields.removeValue(forKey: "engine"), engine != .null {
            guard case let .string(name) = engine, let kind = EngineKind(rawValue: name) else { throw BridgeFailure.invalidCall }
            options.engine = kind
        }
        // A key the bridge does not read would go without effect.
        guard fields.isEmpty else { throw BridgeFailure.invalidCall }
        return options
    }

    /// The place of `arch.tabs.move(id, place)`: `{before}` or `{after}` with a tab's identifier, or `{spaceId}` with a space's, exactly one of them, where a null value counts as missing. Without a place, or with null, the tab goes last in its own space's list.
    private static func tabPlace(_ value: PluginValue?) throws -> PluginTabPlace {
        guard let value, value != .null else { return .end(ofSpace: nil) }
        guard case let .object(fields) = value else { throw BridgeFailure.invalidCall }
        let known: Set = ["before", "after", "spaceId"]
        let given = fields.filter { $0.value != .null }
        // A key the bridge does not read would go without effect, and two places name none. An object without one is a neighbor or a space that the script did not find, as `{before: undefined}`, whose key JSON leaves out, so it is refused rather than taking the tab out of its folder to the end of the list.
        guard fields.keys.allSatisfy(known.contains), given.count == 1, let (key, field) = given.first,
              case let .string(text) = field, let id = UUID(uuidString: text) else { throw BridgeFailure.invalidCall }
        switch key {
        case "before": return .before(id)
        case "after": return .after(id)
        default: return .end(ofSpace: id)
        }
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

        func bool(_ index: Int) throws -> Bool {
            guard case let .bool(value)? = value(index) else { throw BridgeFailure.invalidCall }
            return value
        }

        /// Text, or nil where the script passed none or null.
        func optionalText(_ index: Int) throws -> String? {
            guard let value = value(index), value != .null else { return nil }
            return try text(index)
        }

        /// A whole number, such as a stream's.
        func wholeNumber(_ index: Int) throws -> Int {
            guard case let .number(number)? = value(index), let whole = Int(exactly: number) else { throw BridgeFailure.invalidCall }
            return whole
        }
    }

    /// The reply of one `arch.ai.stream` call: the task that reads it, the text that arrived since the script last asked for more, how the reply ended once it has, and the script's `ai.next` call that waits for either.
    @MainActor
    private final class AIReplyStream {
        var task: Task<Void, Never>?
        var text = ""
        var end: Result<AIFinishReason, any Error>?
        var waiting: (@MainActor @Sendable (Any?, String?) -> Void)?
    }

    private enum BridgeFailure: String, Error {
        case invalidCall
    }
}

private extension AIError {
    /// The case's name, without its associated value.
    var bridgeName: String {
        switch self {
        case .notConfigured: return "notConfigured"
        case .blockedByPolicy: return "blockedByPolicy"
        case .budgetReached: return "budgetReached"
        case .providerUnavailable: return "providerUnavailable"
        case .authentication: return "authentication"
        case .rateLimited: return "rateLimited"
        case .contextTooLong: return "contextTooLong"
        case .invalidRequest: return "invalidRequest"
        case .refused: return "refused"
        case .malformedReply: return "malformedReply"
        case .replyTooLong: return "replyTooLong"
        case .toolRoundLimit: return "toolRoundLimit"
        case .toolCallLimit: return "toolCallLimit"
        case .cancelled: return "cancelled"
        }
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
        case .siteNotGranted: return "siteNotGranted"
        case .invalidPageScript: return "invalidPageScript"
        case .pageScriptFailed: return "pageScriptFailed"
        case .pageRunUnavailable: return "pageRunUnavailable"
        case .invalidAddress: return "invalidAddress"
        case .tooManyTabs: return "tooManyTabs"
        case .hostRefused: return "hostRefused"
        case .networkUnavailable: return "networkUnavailable"
        case .redirectRefused: return "redirectRefused"
        case .rateLimited: return "rateLimited"
        case .responseTooLarge: return "responseTooLarge"
        case .invalidResponse: return "invalidResponse"
        case .invalidRequest: return "invalidRequest"
        }
    }
}
