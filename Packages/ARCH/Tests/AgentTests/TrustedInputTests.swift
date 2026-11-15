// Trusted input in the action tools (docs/agents.md, Actions; Tests ▸ Trusted input), through the tool host on `Fixtures/input.html` in a WebKit web view in a window that is never ordered in, with the agents' target check and a `RecordingInput` over WebKit's input: actions go as trusted input when the call succeeds, at the element's box mapped to the view with the page's zoom, a wheel turn among them, and as DOM events after each `EngineInputError`, for select boxes and file, color, and date inputs, for text with a line break or a control character, for a character key, for a frame's element, for a click on an element with another control at its center, and in a tab the user shared; WebKit's Space types a space into a field and goes as DOM events elsewhere; the target check returns `stale` with nothing clicked or typed where the page moved another element under the point, put another control there inside the element or its label, or moved focus; a failure after typed text says so and counts the form as typed into; an action whose events reach no check returns `stale` and leaves the tab on DOM events, except a pointer move or a wheel turn, which goes again as DOM events; a trusted action waits for the one that still runs in its tab; and the check of a stale action stops cancelling once the user takes the tab. No window is key, so keys need the web view as its window's first responder, and pointer moves, which WebKit sends only in the key window, go as DOM events; pointer moves on screen are checked from the bundle (check 84).
import AgentControl
import AppKit
import ARCHEngine
import Foundation
import Testing
@testable import Agent

@MainActor @Suite(.serialized) struct TrustedInputTests {
    private struct Logged: Decodable, Equatable {
        var type: String
        var trusted: Bool
        var target: String
    }

    /// The events the page logged, in order.
    private func log(_ fixture: PageFixture) async throws -> [Logged] {
        let json = try await fixture.page.evaluate("JSON.stringify(window.inputLog)") as? String
        return try JSONDecoder().decode([Logged].self, from: Data(try #require(json).utf8))
    }

    private func clearLog(_ fixture: PageFixture) async throws {
        _ = try await fixture.page.evaluate("window.inputLog.length = 0; 0")
    }

    private func value(of id: String, in fixture: PageFixture) async throws -> String? {
        try await fixture.page.evaluate("document.getElementById('\(id)').value") as? String
    }

    /// The center of an element of the page, in CSS pixels.
    private func center(of id: String, in fixture: PageFixture) async throws -> CGPoint {
        let json = try await fixture.page.evaluate("(() => { const box = document.getElementById('\(id)').getBoundingClientRect(); return JSON.stringify([box.x + box.width / 2, box.y + box.height / 2]); })()") as? String
        let values = try JSONDecoder().decode([Double].self, from: Data(try #require(json).utf8))
        return CGPoint(x: values[0], y: values[1])
    }

    /// The ref of the outline line that names `name` in quotes.
    private func ref(_ name: String, _ fixture: PageFixture, in lines: [String]) throws -> AgentJSON {
        .string(try #require(fixture.ref("\u{201C}\(name)\u{201D}", in: lines), "\(name)"))
    }

    /// Runs JavaScript in the page's own world without waiting, as a step of the page's own that comes between Arch's checks and the input.
    private func pageStep(_ script: String, in fixture: PageFixture) -> () -> Void {
        { [webView = fixture.page.contents.webView] in MainActor.assumeIsolated { webView.evaluateJavaScript(script, completionHandler: nil) } }
    }

    @Test func anElementsBoxMapsToAPointInTheViewWithZoomAndAScaledVisualViewport() {
        let viewport = AgentVisualViewport(left: 0, top: 0, scale: 1, w: 800, h: 600)
        #expect(AgentToolHost.viewPoint(AgentPoint(x: 70, y: 80), in: viewport, zoomFactor: 1) == CGPoint(x: 70, y: 80))
        #expect(AgentToolHost.viewPoint(AgentPoint(x: 70, y: 80), in: viewport, zoomFactor: 2) == CGPoint(x: 140, y: 160))
        // A pinch zoom scales the visual viewport, which its offset places within the layout viewport.
        let pinched = AgentVisualViewport(left: 100, top: 50, scale: 1.5, w: 400, h: 300)
        #expect(AgentToolHost.viewPoint(AgentPoint(x: 160, y: 90), in: pinched, zoomFactor: 1.25) == CGPoint(x: 112.5, y: 75))
    }

    @Test func keysModifiersAndTextMapToTheEnginesInput() {
        #expect(AgentToolHost.key("Enter")?.0 == .enter && AgentToolHost.key("Enter")?.1 == [])
        #expect(AgentToolHost.key("Space")?.0 == .space && AgentToolHost.key(" ")?.0 == .space)
        #expect(AgentToolHost.key("Meta+A")?.0 == .character("a") && AgentToolHost.key("Meta+A")?.1 == [.command])
        #expect(AgentToolHost.key("Shift+Alt+Tab")?.1 == [.shift, .option])
        for keys in ["F5", "Hyper+A", "é", "", "Control+"] { #expect(AgentToolHost.key(keys) == nil, "\(keys)") }
        // A character key without Command or Control would type its character past P2, P5, and P14, so it keeps DOM events, which type nothing; a shortcut goes.
        for keys in ["a", "Shift+2", "Alt+e", "/"] { #expect(AgentToolHost.inputCalls("press", ["keys": .string(keys)], facts: nil) == nil, "\(keys)") }
        #expect(AgentToolHost.inputCalls("press", ["keys": "Meta+A"], facts: nil) == [.key(.character("a"), [.command])])
        #expect(AgentToolHost.inputCalls("press", ["keys": "Shift+Enter"], facts: nil) == [.key(.enter, [.shift])])
        // Text with a line break or a control character, which can submit a form, keeps DOM events, and so does empty text.
        for text in ["a\nb", "a\r\nb", "a\u{7}b", ""] { #expect(AgentToolHost.inputCalls("type", ["text": .string(text)], facts: nil) == nil, "\(text)") }
        #expect(AgentToolHost.inputCalls("type", ["text": "Héllo 가", "submit": true], facts: nil) == [.text("Héllo 가"), .key(.enter, [])])
        // Select boxes and file, color, date, and time inputs keep DOM events for every action, as does a scroll to an element.
        for facts in [AgentElementFacts(tag: "select", role: "combobox", name: "Size", isSelect: true), AgentElementFacts(tag: "input", role: "button", name: "Receipt", inputType: "file", isFileInput: true)]
            + ["color", "date", "datetime-local", "month", "time", "week"].map({ AgentElementFacts(tag: "input", role: "textbox", name: "Day", inputType: $0) }) {
            for tool in ["click", "press", "hover"] { #expect(AgentToolHost.inputCalls(tool, ["keys": "Enter"], facts: facts) == nil, "\(tool) \(facts.inputType ?? facts.tag)") }
        }
        #expect(AgentToolHost.inputCalls("scroll", ["ref": "e1"], facts: nil) == nil)
        #expect(AgentToolHost.inputCalls("select_option", ["values": ["s"]], facts: nil) == nil)
        #expect(AgentToolHost.inputCalls("click", ["count": 2, "modifiers": ["Shift", "Meta"]], facts: nil) == [.click(count: 2, modifiers: [.shift, .command])])
    }

    @Test func actionsGoAsTrustedInputWhenTheCallSucceeds() async throws {
        let fixture = try await PageFixture("input", trustedInput: true, zoomFactor: 2)
        let input = try #require(fixture.input)
        let lines = await fixture.outline()
        // A click lands at the button's center in the view, at twice its place in the page at twice the page's size, and the page sees it as trusted.
        let click = await fixture.call("click", ["tab": "t1", "ref": try ref("Go", fixture, in: lines)])
        #expect(click.status == .ok && click.structured?["inputKind"] == "trusted", "\(click.text)")
        #expect(click.text.hasSuffix("Arch sent it as the user's own input (inputKind trusted)."))
        let point = try await center(of: "go", in: fixture)
        #expect(input.calls == [.click(CGPoint(x: point.x * 2, y: point.y * 2), count: 1, modifiers: [])])
        #expect(try await log(fixture).filter { $0.type == "click" } == [Logged(type: "click", trusted: true, target: "go")])
        // Typing focuses the field and places the selection: after the text, or over it with replace.
        let name = try ref("Name", fixture, in: lines)
        try await clearLog(fixture)
        let typed = await fixture.call("type", ["tab": "t1", "ref": name, "text": "Robin"])
        #expect(typed.status == .ok && typed.structured?["inputKind"] == "trusted", "\(typed.text)")
        #expect(input.calls.last == .text("Robin"))
        #expect(try await value(of: "name", in: fixture) == "Robin")
        #expect(try await log(fixture).filter { $0.type == "beforeinput" } == [Logged(type: "beforeinput", trusted: true, target: "name")])
        #expect(await fixture.call("type", ["tab": "t1", "ref": name, "text": "Sam", "replace": true]).structured?["inputKind"] == "trusted")
        #expect(await fixture.call("type", ["tab": "t1", "ref": name, "text": " Lee"]).structured?["inputKind"] == "trusted")
        #expect(try await value(of: "name", in: fixture) == "Sam Lee")
        // Enter in the field submits its form; with no window key, WebKit takes keys while the web view is its window's first responder.
        _ = fixture.page.window?.makeFirstResponder(fixture.page.contents.webView)
        try await clearLog(fixture)
        let enter = await fixture.call("press", ["tab": "t1", "ref": name, "keys": "Enter"])
        #expect(enter.status == .ok && enter.structured?["inputKind"] == "trusted", "\(enter.text)")
        #expect(input.calls.last == .press(.enter, []))
        #expect(try await fixture.page.evaluate("document.body.dataset.saved") as? String == "Sam Lee")
        #expect(try await log(fixture).filter { $0.type == "keydown" || $0.type == "submit" } == [Logged(type: "keydown", trusted: true, target: "name"), Logged(type: "submit", trusted: true, target: "form")])
        // WebKit presses no Space: in the focused field a space is typed instead, and on a button the press goes as DOM events.
        let space = await fixture.call("press", ["tab": "t1", "keys": "Space"])
        #expect(space.status == .ok && space.structured?["inputKind"] == "trusted", "\(space.text)")
        #expect(Array(input.calls.suffix(2)) == [.press(.space, []), .text(" ")])
        #expect(try await value(of: "name", in: fixture) == "Sam Lee ")
        // type with submit presses Enter after its text; once the web view is not its window's first responder, WebKit refuses the key, and Enter goes as DOM events.
        let submitted = await fixture.call("type", ["tab": "t1", "ref": name, "text": "!", "submit": true])
        #expect(submitted.status == .ok && submitted.structured?["inputKind"] == "trusted", "\(submitted.text)")
        #expect(Array(input.calls.suffix(2)) == [.text("!"), .press(.enter, [])])
        #expect(try await fixture.page.evaluate("document.body.dataset.saved") as? String == "Sam Lee !")
        _ = fixture.page.window?.makeFirstResponder(nil)
        let refused = await fixture.call("type", ["tab": "t1", "ref": name, "text": "?", "submit": true])
        #expect(refused.status == .ok && refused.structured?["inputKind"] == "dom", "\(refused.text)")
        #expect(try await fixture.page.evaluate("document.body.dataset.saved") as? String == "Sam Lee !?")
        let spaceOnButton = await fixture.call("press", ["tab": "t1", "ref": try ref("Go", fixture, in: lines), "keys": "Space"])
        #expect(spaceOnButton.status == .ok && spaceOnButton.structured?["inputKind"] == "dom", "\(spaceOnButton.text)")
        // A character key goes as DOM events, which type nothing into the field.
        let calls = input.calls.count
        let letter = await fixture.call("press", ["tab": "t1", "ref": name, "keys": "a"])
        #expect(letter.status == .ok && letter.structured?["inputKind"] == "dom" && input.calls.count == calls, "\(letter.text)")
        #expect(try await value(of: "name", in: fixture) == "Sam Lee !?")
        // A scroll in a direction turns the wheel at the viewport's center by the amount in the view's points, and the page sees a trusted wheel event.
        try await clearLog(fixture)
        let scrolled = await fixture.call("scroll", ["tab": "t1", "direction": "down", "amount": 100])
        #expect(scrolled.status == .ok && scrolled.structured?["inputKind"] == "trusted", "\(scrolled.text)")
        guard case .scroll(let at, let deltaX, let deltaY)? = input.calls.last else { Issue.record("No wheel turn: \(input.calls)"); return }
        #expect(deltaX == 0 && deltaY == 200 && at.x > 0 && at.y > 0)
        #expect(try await log(fixture).filter { $0.type == "wheel" } == [Logged(type: "wheel", trusted: true, target: "body")])
        #expect(try await fixture.page.evaluate("scrollY") as? Double == 100 && scrolled.text.hasPrefix("Scrolled t1 to 0, 100."), "\(scrolled.text)")
        // WebKit moves the pointer only in the key window, so a hover goes as DOM events.
        let hover = await fixture.call("hover", ["tab": "t1", "ref": try ref("Go", fixture, in: lines)])
        #expect(hover.status == .ok && hover.structured?["inputKind"] == "dom", "\(hover.text)")
        guard case .move? = input.calls.last else { Issue.record("No pointer move: \(input.calls)"); return }
    }

    @Test func eachEngineInputErrorLeavesTheActionToDOMEvents() async throws {
        let fixture = try await PageFixture("input", trustedInput: true)
        let input = try #require(fixture.input)
        let go = try ref("Go", fixture, in: await fixture.outline())
        for error in [EngineInputError.notInWindow, .outsideView, .noPage, .notFocused, .unsupported] {
            input.failure = error
            try await clearLog(fixture)
            let click = await fixture.call("click", ["tab": "t1", "ref": go])
            #expect(click.status == .ok && click.structured?["inputKind"] == "dom", "\(error): \(click.text)")
            #expect(try await log(fixture).filter { $0.type == "click" } == [Logged(type: "click", trusted: false, target: "go")], "\(error)")
        }
        #expect(input.calls.count == 5)
        // The next call that succeeds goes as trusted input again.
        input.failure = nil
        #expect(await fixture.call("click", ["tab": "t1", "ref": go]).structured?["inputKind"] == "trusted")
    }

    @Test func nativeControlsTextWithALineBreakFramesAndSharedTabsKeepDOMEvents() async throws {
        let fixture = try await PageFixture("input", trustedInput: true)
        let input = try #require(fixture.input)
        let lines = await fixture.outline()
        for name in ["Size", "Color", "Day", "Receipt"] {
            let click = await fixture.call("click", ["tab": "t1", "ref": try ref(name, fixture, in: lines)])
            #expect(click.status == .ok && click.structured?["inputKind"] == "dom", "\(name): \(click.text)")
        }
        let select = await fixture.call("select_option", ["tab": "t1", "ref": try ref("Size", fixture, in: lines), "values": ["Large"]])
        #expect(select.status == .ok && select.structured?["inputKind"] == "dom")
        #expect(try await value(of: "size", in: fixture) == "l")
        let lineBreak = await fixture.call("type", ["tab": "t1", "ref": try ref("Notes", fixture, in: lines), "text": "one\ntwo"])
        #expect(lineBreak.status == .ok && lineBreak.structured?["inputKind"] == "dom")
        #expect(try await value(of: "notes", in: fixture) == "one\ntwo")
        let control = await fixture.call("type", ["tab": "t1", "ref": try ref("Name", fixture, in: lines), "text": "a\u{7}b"])
        #expect(control.status == .ok && control.structured?["inputKind"] == "dom")
        #expect(input.calls.isEmpty, "\(input.calls)")
        // A field in a same-origin frame gets DOM events.
        let framed = try await PageFixture("form", trustedInput: true)
        _ = await framed.outline()
        let coupon = await framed.call("type", ["tab": "t1", "ref": "f1e1", "text": "X", "replace": true])
        #expect(coupon.status == .ok && coupon.structured?["inputKind"] == "dom" && framed.input?.calls.isEmpty == true, "\(coupon.text)")
        // A tab the user shared, whose chooser would open the user's own panel without a P7 card, gets DOM events after the user allows the step.
        let shared = try await PageFixture("input", shared: true, trustedInput: true)
        shared.toolHost.approvals.authenticator = FakeAuthenticator()
        let sharedLines = await shared.outline()
        let sharedGo = try ref("Go", shared, in: sharedLines)
        async let click = shared.call("click", ["tab": "t1", "ref": sharedGo])
        _ = try await shared.answerNextCard(.allowOnce)
        let sharedClick = await click
        #expect(sharedClick.status == .ok && sharedClick.structured?["inputKind"] == "dom" && shared.input?.calls.isEmpty == true, "\(sharedClick.text)")
    }

    /// The target check cancels the input's events whose target the page changed after Arch's checks: a button the page moves under the point on mouseover, which the press sends first, or by its own step before the press, as a timer would, for a click and a double click, and focus that the page moves to another field before the text. No click reaches "Order" and no text the other field. Focus that the page moves after the policy read the focused element makes `press` stale before any key goes. WebKit fires no `focus` event in a page whose window is not key, so the coupon field's focus handler is checked from the bundle (check 84).
    @Test func theTargetCheckCancelsInputThatThePageMovedElsewhere() async throws {
        for (decoy, count, moves) in [("Continue (over)", 1, false), ("Continue (over)", 2, false), ("Continue (timer)", 1, true), ("Continue (timer)", 2, true)] {
            let fixture = try await PageFixture("input", trustedInput: true)
            let lines = await fixture.outline()
            if moves { fixture.input?.before = pageStep("moveOrderOver(document.getElementById('timer'))", in: fixture) }
            let result = await fixture.call("click", ["tab": "t1", "ref": try ref(decoy, fixture, in: lines), "count": .number(Double(count))])
            #expect(result.status == .stale && result.text.contains("put another element under the input"), "\(decoy) \(count): \(result.text)")
            #expect(try await log(fixture).filter { $0.target == "order" && ["mousedown", "mouseup", "click", "dblclick"].contains($0.type) }.isEmpty, "\(decoy) \(count)")
            #expect(try await fixture.page.evaluate("document.body.dataset.ordered ?? ''") as? String == "", "\(decoy) \(count)")
        }
        // A press sends no pointer move, so a page that moves "Order" on mousemove gets the click on the button the agent named.
        let moving = try await PageFixture("input", trustedInput: true)
        let moved = await moving.call("click", ["tab": "t1", "ref": try ref("Continue (move)", moving, in: await moving.outline())])
        #expect(moved.status == .ok && moved.structured?["inputKind"] == "trusted", "\(moved.text)")
        #expect(try await moving.page.evaluate("document.body.dataset.ordered ?? ''") as? String == "")
        #expect(try await log(moving).filter { $0.type == "click" } == [Logged(type: "click", trusted: true, target: "move")])
        // Focus that the page moves after the checks gets no text.
        let focusing = try await PageFixture("input", trustedInput: true)
        let focusLines = await focusing.outline()
        focusing.input?.before = pageStep("document.getElementById('gift').focus()", in: focusing)
        let name = await focusing.call("type", ["tab": "t1", "ref": try ref("Name", focusing, in: focusLines), "text": "Robin"])
        #expect(name.status == .stale && name.text.contains("put another element under the input"), "\(name.text)")
        for id in ["gift", "name"] { #expect(try await value(of: id, in: focusing) == "", "\(id)") }
        // A press goes to the focused element that the policy read: focus the page moves meanwhile makes it stale before any key goes.
        _ = try await focusing.page.evaluate("document.getElementById('name').focus(); 0")
        focusing.input?.before = nil
        var scripts = 0
        let moveFocus = pageStep("document.getElementById('gift').focus()", in: focusing)
        focusing.host.onPageScript = {
            scripts += 1
            if scripts == 2 { moveFocus() }
        }
        let calls = focusing.input?.calls.count
        let press = await focusing.call("press", ["tab": "t1", "keys": "Escape"])
        #expect(press.status == .stale && focusing.input?.calls.count == calls, "\(press.text)")
    }

    @Test func inputThatReachesNoCheckIsStaleAndTheTabKeepsDOMEventsAfterward() async throws {
        let fixture = try await PageFixture("input", trustedInput: true)
        let input = try #require(fixture.input)
        let go = try ref("Go", fixture, in: await fixture.outline())
        input.sendsNothing = true
        let unseen = await fixture.call("click", ["tab": "t1", "ref": go])
        #expect(unseen.status == .stale && unseen.text.contains("through DOM events from now on"), "\(unseen.text)")
        #expect(fixture.state.domInputTabs == [fixture.tabID] && input.calls.count == 1)
        input.sendsNothing = false
        let next = await fixture.call("click", ["tab": "t1", "ref": go])
        #expect(next.status == .ok && next.structured?["inputKind"] == "dom" && input.calls.count == 1, "\(next.text)")
    }

    /// A click or a key reaches the element and no other control inside it or its label (docs/agents.md, Actions): a click on a grid cell whose center holds a Delete button goes as DOM events to the cell; Enter on the cell while its button has focus goes to the cell, which takes focus itself; and a button that the page puts under the point inside a cell, or inside the label of a checkbox, gets no click, and the action is stale.
    @Test func noOtherControlInsideTheElementOrItsLabelGetsTheInput() async throws {
        let fixture = try await PageFixture("input", trustedInput: true)
        let input = try #require(fixture.input)
        var lines = await fixture.outline()
        let cell = await fixture.call("click", ["tab": "t1", "ref": try ref("Row 1", fixture, in: lines)])
        #expect(cell.status == .ok && cell.structured?["inputKind"] == "dom" && input.calls.isEmpty, "\(cell.text)")
        #expect(try await log(fixture).filter { $0.type == "click" } == [Logged(type: "click", trusted: false, target: "cell")])
        _ = try await fixture.page.evaluate("document.getElementById('trash').focus(); 0")
        _ = fixture.page.window?.makeFirstResponder(fixture.page.contents.webView)
        try await clearLog(fixture)
        let enter = await fixture.call("press", ["tab": "t1", "ref": try ref("Row 1", fixture, in: lines), "keys": "Enter"])
        #expect(enter.status == .ok && enter.structured?["inputKind"] == "trusted", "\(enter.text)")
        #expect(try await log(fixture).filter { $0.type == "keydown" } == [Logged(type: "keydown", trusted: true, target: "cell")])
        for (name, step, id) in [("Remember me Why?", "moveOver(document.getElementById('why'), document.getElementById('remember'))", "why"),
                                 ("Row 2", "revealButton(document.getElementById('cell2'))", "inside")] {
            lines = await fixture.outline()
            input.before = pageStep(step, in: fixture)
            try await clearLog(fixture)
            let result = await fixture.call("click", ["tab": "t1", "ref": try ref(name, fixture, in: lines)])
            input.before = nil
            #expect(result.status == .stale && result.text.contains("put another element under the input"), "\(name): \(result.text)")
            #expect(try await log(fixture).filter { $0.target == id && ["mousedown", "mouseup", "click"].contains($0.type) }.isEmpty, "\(name)")
        }
        #expect(try await fixture.page.evaluate("(document.body.dataset.deleted ?? '') + (document.body.dataset.why ?? '')") as? String == "")
    }

    /// Once `type`'s text went, a later failure says so and the form counts as typed into for P5: the page puts a suggestion before the field on input, so the Enter after the text finds its ref stale.
    @Test func aFailureAfterTypedTextSaysSoAndCountsTheFormAsTypedInto() async throws {
        let fixture = try await PageFixture("input", trustedInput: true)
        let search = try ref("Search", fixture, in: await fixture.outline())
        let result = await fixture.call("type", ["tab": "t1", "ref": search, "text": "lamp", "submit": true])
        #expect(result.status == .stale && result.text.contains("Arch had typed the text, or some of it, before that"), "\(result.text)")
        #expect(try await value(of: "search", in: fixture) == "lamp")
        #expect(fixture.state.typedForms[fixture.tabID]?.keys.isEmpty == false)
    }

    /// A pointer move or a wheel turn that reaches no check goes as DOM events and leaves the tab on trusted input, and a trusted action waits for the one that still runs in the tab.
    @Test func aMoveOrAWheelTurnThatReachesNoCheckGoesAsDOMEventsAndActionsWaitTheirTurn() async throws {
        let fixture = try await PageFixture("input", trustedInput: true)
        let input = try #require(fixture.input)
        let go = try ref("Go", fixture, in: await fixture.outline())
        input.sendsNothing = true
        let hover = await fixture.call("hover", ["tab": "t1", "ref": go])
        #expect(hover.status == .ok && hover.structured?["inputKind"] == "dom", "\(hover.text)")
        let scrolled = await fixture.call("scroll", ["tab": "t1", "direction": "down", "amount": 100])
        #expect(scrolled.status == .ok && scrolled.structured?["inputKind"] == "dom", "\(scrolled.text)")
        #expect(try await fixture.page.evaluate("scrollY") as? Double == 100)
        #expect(fixture.state.domInputTabs.isEmpty && input.calls.count == 2)
        input.sendsNothing = false
        fixture.state.inputTabs.insert(fixture.tabID)
        async let waiting = fixture.call("click", ["tab": "t1", "ref": go])
        try await Task.sleep(for: .milliseconds(300))
        #expect(input.calls.count == 2)
        fixture.state.inputTabs.remove(fixture.tabID)
        let click = await waiting
        #expect(click.status == .ok && click.structured?["inputKind"] == "trusted" && input.calls.count == 3, "\(click.text)")
    }

    /// The check of an action that reached no check cancels the input still to come, which the user's own click looks like to it, until the user takes the tab.
    @Test func theCheckOfAStaleActionCancelsNoneOfTheUsersInputOnceTheUserTakesTheTab() async throws {
        let fixture = try await PageFixture("input", trustedInput: true)
        let input = try #require(fixture.input)
        let go = try ref("Go", fixture, in: await fixture.outline())
        input.sendsNothing = true
        #expect(await fixture.call("click", ["tab": "t1", "ref": go]).status == .stale)
        input.sendsNothing = false
        let point = try await center(of: "go", in: fixture)
        try await clearLog(fixture)
        try input.click(at: point, count: 1, modifiers: [])
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await log(fixture).filter { $0.type == "click" }.isEmpty)
        fixture.toolHost.tab(fixture.tabID, of: fixture.grant.id, didReport: .takenOver, state: fixture.state)
        try input.click(at: point, count: 1, modifiers: [])
        var clicks: [Logged] = []
        for _ in 0..<40 where clicks.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            clicks = try await log(fixture).filter { $0.type == "click" }
        }
        #expect(clicks == [Logged(type: "click", trusted: true, target: "go")])
    }
}
