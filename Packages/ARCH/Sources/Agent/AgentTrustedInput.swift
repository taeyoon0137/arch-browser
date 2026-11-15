// Trusted input in the action tools (docs/agents.md, Actions; Risks 18 and 19): in the client's own agent tab, whose engine offers `EngineWebContents.input`, `click`, `type`, `press`, `scroll` in a direction, and `hover` go as the user's own input, at the point in the view that the element's box from the page script maps to, with the target check armed before each call, one action at a time per tab, and the result says `inputKind: trusted`. The action keeps DOM events in a tab the user shared, whose chooser would open the user's own panel without a P7 card, for an element in a frame, for select boxes and file, color, date, and time inputs, whose native controls can track modally on the main thread, for text with a line break or a control character, which the engines refuse because it can submit a form, for keys the engines have no key for, for a character key without Command or Control, which would type its character past the rules that read typing from `type` alone (P2, P5, and P14), for a click whose element has another control at its center, for a `scroll` to an element, which no input event expresses, after an `EngineInputError`, and in a tab whose input once reached no check. A pointer move or a wheel turn that reaches no check goes again as DOM events.
import AgentControl
import ARCHEngine
import Foundation

/// One call of an agent tab's trusted input.
enum AgentInputCall: Equatable {
    case click(count: Int, modifiers: EngineInputModifiers)
    case move
    case text(String)
    case key(EngineKey, EngineInputModifiers)
    /// A wheel turn at the visual viewport's center, by `amount` CSS pixels or 80 percent of the viewport's side.
    case wheel(direction: String, amount: Double?)
}

extension AgentToolHost {
    /// How a trusted action ended.
    enum TrustedInputOutcome {
        /// The input went. `trusted` is false when a later call of the action, the Enter after `type`'s text, went as DOM events.
        case done(AgentActionReply, trusted: Bool)
        /// Nothing went: the action acts through DOM events.
        case useDOM
        case ended(Outcome)
    }

    /// What the target check saw of one call's events.
    private enum InputCheck {
        case delivered
        /// The page put another element under the input, or moved focus, and the check cancelled the input's events.
        case moved
        /// No event reached the check, as when the input landed in another site's frame.
        case unseen
    }

    /// The input types whose native controls can track modally on the main thread.
    static let nativeControlTypes: Set<String> = ["file", "color", "date", "datetime-local", "month", "time", "week"]

    /// The calls of an action as trusted input, or nil when it keeps DOM events.
    static func inputCalls(_ tool: String, _ arguments: [String: AgentJSON], facts: AgentElementFacts?) -> [AgentInputCall]? {
        if let facts, facts.isSelect || facts.isFileInput || facts.inputType.map(nativeControlTypes.contains) == true { return nil }
        switch tool {
        case "click":
            guard let modifiers = modifiers(strings(arguments["modifiers"]) ?? []) else { return nil }
            return [.click(count: arguments["count"].flatMap(integer) ?? 1, modifiers: modifiers)]
        case "hover":
            return [.move]
        case "type":
            guard let text = arguments["text"]?.stringValue, !text.isEmpty, !text.contains(where: \.isNewline),
                  !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
            return [.text(text)] + (arguments["submit"] == .bool(true) ? [.key(.enter, [])] : [])
        case "press":
            guard let (key, modifiers) = key(arguments["keys"]?.stringValue ?? "") else { return nil }
            // A character key without Command or Control types its character into the focused field, where only `type`'s text meets P2, P5, and P14; DOM key events type nothing.
            if case .character = key, modifiers.isDisjoint(with: [.command, .control]) { return nil }
            return [.key(key, modifiers)]
        case "scroll":
            guard arguments["ref"] == nil, let direction = arguments["direction"]?.stringValue else { return nil }
            return [.wheel(direction: direction, amount: arguments["amount"].flatMap(integer).map(Double.init))]
        default:
            return nil
        }
    }

    /// The modifiers that `click` and `press` name, or nil for a name the engines have none for.
    static func modifiers(_ names: [String]) -> EngineInputModifiers? {
        var modifiers: EngineInputModifiers = []
        for name in names {
            switch name {
            case "Shift": modifiers.insert(.shift)
            case "Control": modifiers.insert(.control)
            case "Alt": modifiers.insert(.option)
            case "Meta": modifiers.insert(.command)
            default: return nil
            }
        }
        return modifiers
    }

    /// The key and modifiers of `press`'s `keys`, such as `Enter`, `Space`, or `Meta+A`: a letter names its key in either case, as in a shortcut, and Shift goes only when named. Nil for a key the engines have none for.
    static func key(_ keys: String) -> (EngineKey, EngineInputModifiers)? {
        var parts = keys.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.popLast(), let modifiers = modifiers(parts) else { return nil }
        guard let key = name == "Space" ? .space : EngineKey(domKey: name) else { return nil }
        return (key, modifiers)
    }

    /// Where a point of the page, in CSS pixels of its layout viewport as `getBoundingClientRect()` measures, lies in the page's view, in points from its top-left corner (`EngineInput`).
    static func viewPoint(_ point: AgentPoint, in viewport: AgentVisualViewport, zoomFactor: Double) -> CGPoint {
        CGPoint(x: (point.x - viewport.left) * viewport.scale * zoomFactor, y: (point.y - viewport.top) * viewport.scale * zoomFactor)
    }

    /// Runs an action as trusted input where the tab offers it, after any trusted action that still runs in the tab. Each call's preparation checks the element again, as `act` does, and arms the target check; the call then waits until the check has the call's events, cancelled ones included, so that an action whose events the check cancelled is `stale`, and one whose first event does not come within `inputCheckWait` is `stale` too, after which the tab acts through DOM events; a pointer move or a wheel turn that does not come goes again as DOM events instead. Once `type`'s text went, `didType` records the form for P5 at once, and a failure after it says that the field may hold the text.
    func trustedAction(_ tool: String, _ arguments: [String: AgentJSON], tab: AgentTabInfo, handle: String, access: AgentTabAccess, target: AgentRefTarget?, facts: AgentElementFacts?,
                       state: AgentGrantState, didType: () -> Void) async -> TrustedInputOutcome {
        guard access == .agentTab, (target?.frame ?? 0) == 0, let calls = Self.inputCalls(tool, arguments, facts: facts) else { return .useDOM }
        // The target check holds one action's check, which another action's arming would replace while the first one's events still come.
        while state.inputTabs.contains(tab.id) {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return .ended(Self.ended) }
        }
        guard !state.domInputTabs.contains(tab.id), let input = host.trustedInput(of: tab.id) else { return .useDOM }
        state.inputTabs.insert(tab.id)
        defer { state.inputTabs.remove(tab.id) }
        var hit: String?
        var typed = false
        func end(_ outcome: Outcome) -> TrustedInputOutcome {
            guard typed, case .text(let text)? = outcome.result.content.first else { return .ended(outcome) }
            var outcome = outcome
            outcome.result.content[0] = .text(text + " Arch had typed the text, or some of it, before that, so read the field before you type again.")
            return .ended(outcome)
        }
        func enterThroughDOM() async -> TrustedInputOutcome {
            let outcome = await pressEnterThroughDOM(target, tab: tab, handle: handle, hit: hit)
            if case .ended(let failure) = outcome { return end(failure) }
            return outcome
        }
        for (index, call) in calls.enumerated() {
            let reply: AgentInputReply
            switch await pageScript(.prepare(preparation(for: call, tool: tool, arguments: arguments, target: target, facts: facts)), in: tab, as: AgentInputReply.self, handle: handle) {
            case .outcome(let failure): return end(failure)
            case .value(let value): reply = value
            }
            if let problem = reply.problem {
                if ["noCheck", "inFrame", "noFocus", "noSelection", "readOnly", "inner"].contains(problem) { return index == 0 ? .useDOM : await enterThroughDOM() }
                return end(Self.unreachable(problem, cover: reply.cover, ref: target?.ref ?? "", handle: handle, tool: tool) ?? Self.error("notInteractable", "\(handle) could not \(tool) there."))
            }
            guard let token = reply.token else { return index == 0 ? .useDOM : await enterThroughDOM() }
            hit = hit ?? reply.hit
            do {
                try send(call, through: input, reply: reply)
            } catch EngineInputError.unsupported where call == .key(.space, []) && reply.editable == true {
                // An engine that presses no Space types one into the field that would receive it.
                guard case .value = await pageScript(.inputState(token: token, need: AgentInputNeed(text: 1), cancelRest: false, disarm: false), in: tab, as: AgentInputState.self, handle: handle),
                      (try? input.input.insertText(" ")) != nil else {
                    await endCheck(token, in: tab, handle: handle)
                    return .useDOM
                }
            } catch {
                await endCheck(token, in: tab, handle: handle)
                return index == 0 ? .useDOM : await enterThroughDOM()
            }
            if case .text = call {
                typed = true
                didType()
            }
            switch await awaitInput(call, token: token, in: tab, handle: handle) {
            case .outcome(let failure): return end(failure)
            case .value(.delivered): continue
            case .value(.moved):
                return end(Outcome(result: AgentToolResult(status: .stale, code: "stale", text: "The page in \(handle) put another element under the input, or moved focus, so Arch cancelled it. Take a new snapshot.",
                                                           structured: ["tab": .string(handle)])))
            case .value(.unseen) where Self.activatesNothing(call):
                return .useDOM
            case .value(.unseen):
                state.domInputTabs.insert(tab.id)
                return end(Outcome(result: AgentToolResult(status: .stale, code: "stale",
                                                           text: "No event of the input reached the element in \(handle), as when the page puts another site's frame over it. Take a new snapshot; Arch acts in \(handle) through DOM events from now on.",
                                                           structured: ["tab": .string(handle)])))
            }
        }
        return .done(AgentActionReply(url: tab.url?.absoluteString ?? "", hit: hit), trusted: true)
    }

    /// A pointer move and a wheel turn give the page no activation, so one that reaches no check goes again as DOM events, and the tab keeps trusted input.
    private static func activatesNothing(_ call: AgentInputCall) -> Bool {
        switch call {
        case .move, .wheel: true
        default: false
        }
    }

    /// What `prepare` readies for one call: the element, the events the check looks at, and the counts after which the call's events have all come.
    private func preparation(for call: AgentInputCall, tool: String, arguments: [String: AgentJSON], target: AgentRefTarget?, facts: AgentElementFacts?) -> AgentInputPreparation {
        let pointer = ["pointerover", "mouseover"]
        let keys = ["keydown", "keypress", "keyup", "beforeinput"]
        let hold = Int(((inputCheckWait * 3) + 1) * 1000)
        switch call {
        case .click(let count, _):
            return AgentInputPreparation(kind: "click", ref: target, kinds: pointer + ["pointerdown", "mousedown", "pointerup", "mouseup", "click", "dblclick"], need: AgentInputNeed(clicks: count), holdMs: hold)
        case .move:
            return AgentInputPreparation(kind: "hover", ref: target, kinds: pointer + ["pointermove", "mousemove"], need: AgentInputNeed(moves: 1), holdMs: hold)
        case .text(let text):
            return AgentInputPreparation(kind: "type", ref: target, replace: arguments["replace"] == .bool(true), kinds: keys, need: AgentInputNeed(text: text.utf16.count), holdMs: hold)
        case .key:
            return AgentInputPreparation(kind: "press", ref: target, focus: target == nil ? facts.map(AgentFocusedElement.init) : nil, kinds: keys, need: AgentInputNeed(keyups: 1), holdMs: hold)
        case .wheel:
            return AgentInputPreparation(kind: "scroll", kinds: ["wheel"], need: AgentInputNeed(wheels: 1), holdMs: hold)
        }
    }

    private func send(_ call: AgentInputCall, through tabInput: AgentTabInput, reply: AgentInputReply) throws {
        let input = tabInput.input
        let zoom = tabInput.zoomFactor
        func point() throws -> CGPoint {
            guard let point = reply.point else { throw EngineInputError.outsideView }
            return Self.viewPoint(point, in: reply.viewport, zoomFactor: zoom)
        }
        switch call {
        case .click(let count, let modifiers): try input.click(at: point(), count: count, modifiers: modifiers)
        case .move: try input.movePointer(to: point(), modifiers: [])
        case .text(let text): try input.insertText(text)
        case .key(let key, let modifiers): try input.press(key, modifiers: modifiers)
        case .wheel(let direction, let amount):
            let viewport = reply.viewport
            let across = direction == "left" || direction == "right"
            let distance = (amount ?? ((across ? viewport.w : viewport.h) * 0.8).rounded()) * viewport.scale * zoom * (direction == "up" || direction == "left" ? -1 : 1)
            let center = Self.viewPoint(AgentPoint(x: viewport.left + viewport.w / 2, y: viewport.top + viewport.h / 2), in: viewport, zoomFactor: zoom)
            try input.scroll(at: center, deltaX: across ? distance : 0, deltaY: across ? 0 : distance, modifiers: [])
        }
    }

    /// Reads the target check that `token` armed until it has the call's events, cancelled ones included. A check that the page's next document replaced counts as delivered. One that has seen no event after `inputCheckWait` cancels the input's events still to come while it holds, or for a pointer move or a wheel turn ends; one that has seen some but not all after three times that ends, or keeps cancelling when it cancelled one.
    private func awaitInput(_ call: AgentInputCall, token: Int, in tab: AgentTabInfo, handle: String) async -> Resolved<InputCheck> {
        let start = Date()
        while true {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled {
                endCheckLater(token, in: tab)
                return .outcome(Self.ended)
            }
            let current: AgentInputState
            switch await pageScript(.inputState(token: token, need: nil, cancelRest: false, disarm: false), in: tab, as: AgentInputState.self, handle: handle) {
            case .outcome(let failure): return .outcome(failure)
            case .value(let value): current = value
            }
            if current.complete || !current.armed { return .value(current.cancelled ? .moved : .delivered) }
            let waited = Date().timeIntervalSince(start)
            if current.seen == 0, waited >= inputCheckWait {
                let ends = Self.activatesNothing(call)
                _ = await pageScript(.inputState(token: token, need: nil, cancelRest: !ends, disarm: ends), in: tab, as: AgentInputState.self, handle: handle)
                return .value(.unseen)
            }
            if waited >= inputCheckWait * 3 {
                if !current.cancelled { await endCheck(token, in: tab, handle: handle) }
                return .value(current.cancelled ? .moved : .delivered)
            }
        }
    }

    private func endCheck(_ token: Int, in tab: AgentTabInfo, handle: String) async {
        _ = await pageScript(.inputState(token: token, need: nil, cancelRest: false, disarm: true), in: tab, as: AgentInputState.self, handle: handle)
    }

    /// Ends the check of a call that was cancelled, without waiting for the page.
    private func endCheckLater(_ token: Int, in tab: AgentTabInfo) {
        host.runPageScript(AgentPageScripts.source(for: .inputState(token: token, need: nil, cancelRest: false, disarm: true)), world: AgentPageScripts.world, in: tab.id) { _ in }
    }

    /// Ends whatever the tab's target check holds, without waiting for the page, once the user acts in the tab: at Take Over, at `hand_to_user`, and when the tab leaves its agent folder, so that the check of an action that ended `stale` cancels none of the user's own input.
    func releaseInputCheck(in tabID: UUID) {
        host.runPageScript(AgentPageScripts.source(for: .releaseInput), world: AgentPageScripts.world, in: tabID) { _ in }
    }

    /// The Enter of `type` with `submit` through DOM events, once its text went as trusted input and the engine refused the key, as WebKit does while the tab's window is not key.
    private func pressEnterThroughDOM(_ target: AgentRefTarget?, tab: AgentTabInfo, handle: String, hit: String?) async -> TrustedInputOutcome {
        switch await pageScript(.act(AgentPageAction(kind: "press", ref: target, keys: "Enter")), in: tab, as: AgentActionReply.self, handle: handle) {
        case .outcome(let failure): return .ended(failure)
        case .value(let reply):
            if let problem = reply.problem {
                return .ended(Self.unreachable(problem, cover: reply.cover, ref: target?.ref ?? "", handle: handle, tool: "type") ?? Self.error("notInteractable", "\(handle) could not type there."))
            }
            return .done(AgentActionReply(url: reply.url, hit: hit ?? reply.hit), trusted: false)
        }
    }
}
