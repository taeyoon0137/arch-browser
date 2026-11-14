// The agents' page script in WebKit web views without a window over a non-persistent store, through the tool host, on the fixture pages (docs/agents.md, Page snapshots and refs; Tests ▸ Page scripts): roles, names, refs and fingerprints, stale refs after a DOM change and a navigation, hidden elements, open shadow roots, same-origin frames, other sites' frames listed, each redaction rule and the personal class, no values in shared tabs, extension frames left out, the boxes and a screenshot with a filled password field painted over, fields and frames inside aria-hidden and inert subtrees painted over, every field painted over in a shared tab, which no step moves before the user decides, annotations, a page that replaced built-ins, actionability and covers, typing into a framework-style controlled input, selects, Enter submission with the form's default button, no user activation in the page's handlers, the element facts the rules read, a search form's hidden input, a page that changes before its document finishes, captures that do not answer, no full-page screenshot of a Chromium page with boxes, a call stopped before its card, cuts, and the diff.
import AgentControl
import AppKit
import Foundation
import Testing
@testable import Agent

@MainActor @Suite(.serialized) struct PageScriptTests {
    private func session(sharing fixture: PageFixture) -> AgentSession {
        fixture.host.userTabIDs.insert(fixture.tabID)
        var scope = AgentSiteScope()
        scope.add(fixture.page.url)
        return AgentSession(title: "Read this page", personaID: FakeHost.defaultPersona.id, spaceID: fixture.grant.spaceID, origin: .app, mode: .readOnly,
                            model: nil, effort: nil, scope: scope, attachedTabIDs: [fixture.tabID], tools: [])
    }

    @Test func aSharedSessionOutlineRedactsValuesAndScopesRefsAndDiffsToItsDocument() async throws {
        let fixture = try await PageFixture(shared: true)
        let session = session(sharing: fixture)
        func snapshot(_ handle: String = "t1", diff: Bool = false, ref: String? = nil) async -> AgentToolResult {
            var args: [String: AgentJSON] = ["tab": .string(handle), "diff": .bool(diff)]
            args["ref"] = ref.map(AgentJSON.string)
            return await fixture.toolHost.run(AgentToolCall(name: "snapshot", arguments: args), in: session, searchesHistory: false)
        }
        let original = await snapshot()
        #expect(original.status == .ok && original.text.contains("Place order"))
        let converted = AgentAPISession.result(original, of: AgentToolCall(name: "snapshot", arguments: ["tab": "t1"]), callID: "outline")
        let pages = converted.parts.compactMap { part -> String? in
            if case .page(let page) = part { return page.text }
            return nil
        }
        #expect(!converted.isError && pages.count == 1 && pages[0].contains("Place order") && !pages[0].contains("Alex Kim"))
        for secret in ["Alex Kim", "Leave at the door", "SAVE10", "Standard", "session=secret"] { #expect(!original.text.contains(secret)) }
        #expect(await snapshot(ref: "e17").status == .ok)
        #expect((await snapshot(diff: true)).text.contains("Nothing changed"))
        fixture.host.tabs[0].documentID = UUID()
        _ = try await fixture.page.evaluate("document.querySelectorAll('button').forEach(b => { if (b.textContent.includes('Place order')) b.textContent = 'Continue'; })")
        #expect(await snapshot(ref: "e17").status == .stale)
        let replaced = await snapshot(diff: true)
        #expect(replaced.status == .ok && replaced.text.contains("Continue") && replaced.text.contains("first snapshot") && !replaced.text.contains("Place order"))

        session.unshare(tabID: fixture.tabID)
        #expect(await snapshot().code == "tabNotFound")
        let fresh = session.share(tabID: fixture.tabID, url: fixture.page.url)
        #expect(fresh != "t1" && session.snapshots.records.isEmpty)
        #expect(await snapshot(fresh, ref: "e17").status == .stale)
        #expect((await snapshot(fresh, diff: true)).text.contains("first snapshot"))
        session.stop()
        #expect(session.snapshots.records.isEmpty)
        #expect(await snapshot(fresh, ref: "e17").status == .stale)
    }

    @Test func takingOverAnActiveOutlineAndHandingBackDropsItsContentsRefsAndDiff() async throws {
        let fixture = try await PageFixture(shared: true)
        let session = session(sharing: fixture)
        var call = AgentToolCall(name: "snapshot", arguments: ["tab": "t1", "diff": true])
        var validations: [UUID?] = []
        let excluded = AgentToolHost(host: fixture.host, allowsAI: { _ in
            validations.append(session.latestActiveTab)
            return false
        })
        let denied = await excluded.run(call, in: session, searchesHistory: false)
        #expect(denied.code == "P16" && validations.count == 1 && validations[0] == nil)
        let original = await fixture.toolHost.run(call, in: session, searchesHistory: false)
        #expect(original.status == .ok && session.snapshots.records[fixture.tabID] != nil)
        let oldStore = session.snapshots
        fixture.host.onPageScript = {
            #expect(session.latestActiveTab == fixture.tabID)
            session.takeOver()
            session.handBack()
        }
        let interrupted = await fixture.toolHost.run(call, in: session, searchesHistory: false)
        #expect(interrupted.status == .refused && interrupted.structured?["outline"] == nil && !interrupted.text.contains("Place order"))
        #expect(session.latestActiveTab == nil && session.snapshots !== oldStore && session.snapshots.records.isEmpty && session.snapshots.counts.isEmpty)
        #expect(oldStore.counts[fixture.tabID] == 1)
        fixture.host.onPageScript = nil
        call.arguments["ref"] = "e17"
        #expect(await fixture.toolHost.run(call, in: session, searchesHistory: false).status == .stale)
        call.arguments["ref"] = nil
        let fresh = await fixture.toolHost.run(call, in: session, searchesHistory: false)
        #expect(fresh.status == .ok && fresh.text.contains("first snapshot") && !fresh.text.contains("Alex Kim"))
    }

    @Test func aSessionChecksItsAttachmentAndDocumentAgainAfterAnOutline() async throws {
        let fixture = try await PageFixture(shared: true)
        let session = session(sharing: fixture)
        let call = AgentToolCall(name: "snapshot", arguments: ["tab": "t1"])
        fixture.host.onPageScript = { fixture.host.tabs[0].documentID = UUID() }
        let stale = await fixture.toolHost.run(call, in: session, searchesHistory: false)
        #expect(stale.code == "pageChanged" && !stale.text.contains("Place order") && session.snapshots.records.isEmpty)
        fixture.host.onPageScript = {
            session.unshare(tabID: fixture.tabID)
            _ = session.share(tabID: fixture.tabID, url: fixture.page.url)
        }
        let revoked = await fixture.toolHost.run(call, in: session, searchesHistory: false)
        #expect(revoked.status == .refused && revoked.code == "P17" && session.snapshots.records.isEmpty)
        fixture.host.onPageScript = nil
        let handle = session.handles.tabs.handle(for: fixture.tabID)
        let current = AgentToolCall(name: "snapshot", arguments: ["tab": .string(handle)])
        fixture.host.userTabIDs = []
        #expect(await fixture.toolHost.run(current, in: session, searchesHistory: false).code == "P17")
        fixture.host.userTabIDs = [fixture.tabID]
        let excluded = AgentToolHost(host: fixture.host, allowsAI: { _ in false })
        #expect(await excluded.run(current, in: session, searchesHistory: false).code == "P16")
    }

    @Test func cancellingASessionOutlineReleasesASilentPageWithoutCreatingRefs() async throws {
        let fixture = try await PageFixture(shared: true)
        let session = session(sharing: fixture)
        let call = AgentToolCall(name: "snapshot", arguments: ["tab": "t1"])
        fixture.host.silentTabIDs = [fixture.tabID]
        var started = false
        fixture.host.onPageScript = { started = true }
        let read = Task { await fixture.toolHost.run(call, in: session, searchesHistory: false) }
        try await waitUntil { started }
        let stop = ContinuousClock.now
        read.cancel()
        let result = await read.value
        #expect(ContinuousClock.now - stop < .seconds(1))
        #expect(result.code == "ended" && session.snapshots.records.isEmpty)
    }

    @Test func theOutlineHasRolesNamesRefsAndFingerprints() async throws {
        let fixture = try await PageFixture()
        let result = await fixture.call("snapshot", ["tab": "t1"])
        #expect(result.status == .ok)
        #expect(result.text.hasPrefix("t1 \u{00B7} webKit \u{00B7} snapshot 1\n<untrusted source=\"page\" url=\"https://fixture.example/form.html\">page \u{201C}Checkout \u{2013} Example\u{201D} fixture.example/form.html"))
        let lines = await fixture.outline()
        for expected in [
            "- banner",
            "  - link \u{201C}Home\u{201D} [e1] \u{2192} fixture.example/",
            "  - searchbox \u{201C}Search\u{201D} [e2] value=\u{201C}\u{201D}",
            "- navigation \u{201C}Steps\u{201D}",
            "  - link \u{201C}Cart\u{201D} [e3] \u{2192} fixture.example/cart",
            "  - heading \u{201C}Your order\u{201D} level=1",
            "  - textbox \u{201C}Name\u{201D} [e6] value=\u{201C}Alex Kim\u{201D}",
            "  - combobox \u{201C}Shipping\u{201D} [e11] value=\u{201C}Standard\u{201D}",
            "  - checkbox \u{201C}Gift wrap\u{201D} [e12] not checked",
            "  - textbox \u{201C}Message\u{201D} [e14] value=\u{201C}Hi\u{201D}",
            "  - button \u{201C}Place order\u{201D} [e17] submits form (asks the user)",
            "  - button \u{201C}Disabled\u{201D} [e18] disabled",
        ] {
            #expect(lines.contains(expected), "\(expected)")
        }
        // The host keeps each ref's fingerprint with the document's address, and a link's full address, query and fragment included, which the outline shows reduced.
        let record = try #require(fixture.state.snapshots.records[fixture.tabID])
        #expect(record.url == fixture.page.url)
        #expect(record.refs["e17"]?.fingerprint == "button|button||Place order")
        #expect(record.refs["e6"]?.fingerprint == "input|textbox|text|Name")
        #expect(record.refs["e3"]?.href == URL(string: "https://fixture.example/cart?session=secret#top"))
        #expect(!result.text.contains("session=secret"))
    }

    @Test func fieldsTheScriptNeverReveals() async throws {
        let fixture = try await PageFixture()
        let result = await fixture.call("snapshot", ["tab": "t1", "mode": "full"])
        let lines = await fixture.outline(["mode": "full"])
        // Password, payment, and one-time-code fields, labels that name a secret in English and Korean, a same-origin frame's PIN, and hidden inputs give no value.
        for secret in ["hunter2", "hunter3", "4111111111111111", "123456", "9999", "token-secret"] { #expect(!result.text.contains(secret), "\(secret)") }
        #expect(lines.contains("  - textbox \u{201C}Password\u{201D} [e7] value hidden (agents do not type here)"))
        #expect(lines.contains("  - textbox \u{201C}Card number\u{201D} [e8] value hidden (agents do not type here)"))
        #expect(lines.contains("  - textbox \u{201C}Verification code\u{201D} [e9] value hidden (agents do not type here)"))
        #expect(lines.contains("  - textbox \u{201C}\u{BE44}\u{BC00}\u{BC88}\u{D638} \u{D655}\u{C778}\u{201D} [e10] value hidden (agents do not type here)"))
        #expect(lines.contains("    - textbox \u{201C}Coupon PIN\u{201D} [f1e2] value hidden (agents do not type here)"))
        // Personal data shows as <personal>, and asks the user before typing (P2).
        for personal in ["me@example.org", "010-1234-5678"] { #expect(!result.text.contains(personal), "\(personal)") }
        #expect(lines.contains("  - textbox \u{201C}Email\u{201D} [e4] value=<personal> (asks the user)"))
        #expect(lines.contains("  - textbox \u{201C}Phone\u{201D} [e5] value=<personal> (asks the user)"))
        // Full mode adds the page's visible text, but never a label's again.
        #expect(lines.contains("  - text \u{201C}Questions?\u{201D}"))
        #expect(lines.contains("    - text \u{201C}We use cookies.\u{201D}"))
        #expect(!lines.contains("  - text \u{201C}Email\u{201D}"))
    }

    @Test func hiddenElementsShadowRootsAndFrames() async throws {
        let fixture = try await PageFixture()
        let lines = await fixture.outline()
        let text = lines.joined(separator: "\n")
        // Hidden elements and aria-hidden subtrees are left out, as are extension frames, such as a password manager's menu.
        #expect(!text.contains("Hidden by ARIA") && !text.contains("Hidden by style") && !text.contains("Saved logins"))
        // An open shadow root's button, a same-origin frame walked with its own refs, and another site's frame listed but not read.
        #expect(lines.contains("  - button \u{201C}Shadow button\u{201D} [e19]"))
        #expect(lines.contains("  - frame \u{201C}Coupon\u{201D}"))
        #expect(lines.contains("    - textbox \u{201C}Coupon\u{201D} [f1e1] value=\u{201C}SAVE10\u{201D}"))
        #expect(lines.contains("    - button \u{201C}Apply\u{201D} [f1e3]"))
        #expect(lines.contains("  - frame \u{201C}Payments\u{201D} (another site; not read)"))
        #expect(!text.contains("4111"))
        // The policy's annotations: file inputs, CAPTCHAs, and controls that read as a step that cannot be undone.
        #expect(lines.contains("  - button \u{201C}Receipt\u{201D} [e15] (agents do not choose files)"))
        #expect(lines.contains("  - checkbox \u{201C}I'm not a robot\u{201D} [e16] not checked (CAPTCHA: hand to the user)"))
        #expect(lines.contains("    - button \u{201C}Accept\u{201D} [e22] (asks the user)"))
        #expect(lines.contains("  - button \u{201C}Remove item\u{201D} [e27] (asks the user)"))
    }

    @Test func sharingATakenOverDocumentCannotDiffTheEarlierUnredactedOutline() async throws {
        let fixture = try await PageFixture()
        let owned = await fixture.call("snapshot", ["tab": "t1"])
        #expect(owned.text.contains("Alex Kim"))
        fixture.host.tabs[0].agentOwnerID = nil
        fixture.host.userTabIDs.insert(fixture.tabID)
        fixture.state.handles.sharedTabIDs.append(fixture.tabID)
        let storedRef = await fixture.call("snapshot", ["tab": "t1", "ref": "e6"])
        #expect(storedRef.status == .stale)
        let shared = await fixture.call("snapshot", ["tab": "t1", "diff": true])
        #expect(shared.status == .ok && shared.text.contains("first snapshot") && !shared.text.contains("Alex Kim"))
    }

    @Test func aTabTheUserSharedShowsNoValues() async throws {
        let fixture = try await PageFixture(shared: true)
        let result = await fixture.call("snapshot", ["tab": "t1"])
        #expect(result.text.contains("shared by the user: every action here asks"))
        for value in ["Alex Kim", "Leave at the door", "SAVE10", "Standard"] { #expect(!result.text.contains(value), "\(value)") }
        let lines = await fixture.outline()
        #expect(lines.contains("  - textbox \u{201C}Name\u{201D} [e6] (asks the user)"))
        #expect(lines.contains("  - textbox \u{201C}Password\u{201D} [e7] value hidden (agents do not type here)"))
    }

    @Test func refsGoStaleWhenThePageChanges() async throws {
        let fixture = try await PageFixture()
        _ = await fixture.outline()
        // A subtree snapshot by ref.
        let subtree = await fixture.outline(["ref": "e17"])
        #expect(subtree == ["- button \u{201C}Place order\u{201D} [e17] submits form (asks the user)"])
        // A button added before e17 shifts the walk: the element at e17 is no longer the same, so the action and the subtree are stale.
        _ = try await fixture.page.evaluate("document.querySelector('#checkout button').before(Object.assign(document.createElement('button'), { type: 'button', textContent: 'Apply coupon' })); 0")
        let click = await fixture.call("click", ["tab": "t1", "ref": "e17"])
        #expect(click.status == .stale && click.text == "The page in t1 changed since your last snapshot. Take a new snapshot.")
        #expect(await fixture.call("snapshot", ["tab": "t1", "ref": "e17"]).status == .stale)
        // A ref no snapshot gave, and every ref once the tab shows another document.
        #expect(await fixture.call("click", ["tab": "t1", "ref": "e99"]).status == .stale)
        _ = await fixture.outline()
        fixture.state.record(.report(.loaded(url: fixture.page.url, title: "Again")), tab: fixture.tabID)
        #expect(await fixture.call("hover", ["tab": "t1", "ref": "e1"]).status == .stale)
    }

    @Test func theDiffAndTheCut() async throws {
        let fixture = try await PageFixture()
        let first = await fixture.call("snapshot", ["tab": "t1", "diff": true])
        #expect(first.text.contains("This is the first snapshot of t1, so it shows the whole outline."))
        let unchanged = await fixture.call("snapshot", ["tab": "t1", "diff": true])
        #expect(unchanged.text.contains("Nothing changed since the last snapshot of t1."))
        _ = try await fixture.page.evaluate("document.querySelector('#under').textContent = 'Still covered'; 0")
        let diff = await fixture.outline(["diff": true])
        #expect(diff == ["-   - button \u{201C}Covered\u{201D} [e21]", "+   - button \u{201C}Still covered\u{201D} [e21]"])
        // A cut lands on a line's end and says how to get the rest.
        let cut = await fixture.call("snapshot", ["tab": "t1", "max_chars": 300])
        #expect(cut.text.contains("The outline was cut at") && cut.text.contains("read_text"))
        let block = try #require(cut.structured?["outline"]?.stringValue)
        #expect(block.count < 600)
        #expect(cut.structured?["limits"]?["leftOutLines"] != nil)
    }

    @Test(arguments: ["reload", "closed", "excluded", "takenOver"])
    func anImageNeverLeavesATabThatChangesDuringTheCapture(_ change: String) async throws {
        let fixture = try await PageFixture()
        let host = fixture.host
        host.onCapture = { [unowned host] in
            switch change {
            case "reload": host.tabs[0].documentID = UUID()
            case "closed": host.tabs.removeAll()
            case "excluded": host.tabs[0].url = URL(string: "https://excluded.example/")
            default: host.tabs[0].agentOwnerID = nil
            }
        }
        let result = await fixture.call("screenshot", ["tab": "t1", "area": "viewport"])
        #expect(result.status != .ok)
        #expect(!result.content.contains { if case .image = $0 { return true }; return false })
    }

    @Test func theBoxesAndAScreenshotWithTheFilledPasswordFieldPaintedOver() async throws {
        let fixture = try await PageFixture()
        // The user typed a password into the page, which a capture shows as dots unless it is painted over.
        _ = try await fixture.page.evaluate("const f = document.querySelector('[name=password]'); f.value = 'typed-by-the-user'; f.style.background = 'rgb(255, 0, 0)'; f.style.color = 'rgb(255, 0, 0)'; 0")
        let tab = try #require(fixture.host.tabs.first)
        guard case .value(let boxes) = await fixture.toolHost.pageScript(.boxes(shared: false), in: tab, as: AgentBoxesReply.self) else { Issue.record("The boxes did not read."); return }
        #expect(boxes.viewport == AgentSize(w: 1024, h: 768))
        #expect(Set(boxes.boxes.map(\.kind)) == ["hidden", "personal", "frame", "extension"])
        #expect(boxes.boxes.filter { $0.kind == "frame" }.count == 1 && boxes.boxes.filter { $0.kind == "extension" }.count == 1)
        let shot = await fixture.call("screenshot", ["tab": "t1", "area": "viewport"])
        #expect(shot.status == .ok, "\(shot.text)")
        #expect(shot.text.hasPrefix("t1: a screenshot of the viewport, 1,568 \u{00D7} 1,176 pixels, JPEG. Arch painted over"))
        let data = try #require(shot.content.compactMap(\.imageData).first)
        #expect(data.count <= AgentLimits.screenshotBytes && shot.content.contains { if case .image(_, "image/jpeg") = $0 { return true } else { return false } })
        // The page the image shows, as read_text names it, from which an API-key session names the image's source.
        #expect(shot.structured?["url"] == "https://fixture.example/form.html")
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(max(image.pixelsWide, image.pixelsHigh) <= AgentLimits.screenshotLongestSide)
        // The password field's box is the painted gray, not the page's red.
        let password = try #require(boxes.boxes.first { $0.kind == "hidden" })
        let scale = Double(image.pixelsWide) / boxes.viewport.w
        let color = try #require(image.colorAt(x: Int((password.x + password.w / 2) * scale), y: Int((password.y + password.h / 2) * scale))?.usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - 0.55) < 0.08 && abs(color.greenComponent - 0.55) < 0.08, "\(color) at \(password) of \(image.pixelsWide)x\(image.pixelsHigh)")
        // Outside the painted boxes, the page shows as it is.
        let name = try #require(image.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
        #expect(name.redComponent > 0.9, "\(name)")
        // An element's screenshot is cropped to it, and a full page's comes from the whole document.
        _ = await fixture.outline()
        let element = await fixture.call("screenshot", ["tab": "t1", "area": "e17"])
        #expect(element.status == .ok && element.text.contains("a screenshot of the element e17"))
        let full = await fixture.call("screenshot", ["tab": "t1", "area": "full"])
        #expect(full.status == .ok && full.text.contains("a screenshot of the full page"))
        // A tab whose capture comes back empty, as Chromium's may while no window shows it, gets notVisible.
        let blank = UUID()
        fixture.host.tabs.append(AgentTabInfo(id: blank, spaceID: fixture.grant.spaceID, title: "Blank", url: fixture.page.url, isLoading: false, engine: .chromium, agentOwnerID: fixture.grant.id))
        fixture.host.webContents[blank] = fixture.page.contents
        let handle = fixture.state.handles.tabs.handle(for: blank)
        fixture.host.captures[blank] = NSImage(size: NSSize(width: 10, height: 10))
        let notVisible = await fixture.call("screenshot", ["tab": .string(handle), "area": "viewport"])
        #expect(notVisible.status == .error && notVisible.code == "notVisible" && notVisible.text == "\(handle) cannot be captured while no window shows it. Read it with snapshot.")
        // Chromium's full-page capture lays the page out again, which can move what the boxes cover, so a Chromium page with boxes gets none.
        fixture.host.captures[blank] = nil
        let chromiumFull = await fixture.call("screenshot", ["tab": .string(handle), "area": "full"])
        #expect(chromiumFull.status == .error && chromiumFull.code == "notAvailable" && chromiumFull.content.compactMap(\.imageData).isEmpty)
        #expect(chromiumFull.text.hasPrefix("\(handle) has private fields or frames that Arch paints over"))
    }

    @Test func aPageThatReplacedBuiltInsCannotReachWebKitsOwnWorld() async throws {
        let fixture = try await PageFixture("tampered")
        let result = await fixture.call("snapshot", ["tab": "t1"])
        #expect(result.status == .ok)
        let lines = await fixture.outline()
        #expect(lines == ["- button \u{201C}Real button\u{201D} [e1]", "- textbox \u{201C}Password\u{201D} [e2] value hidden (agents do not type here)"])
        #expect(!result.text.contains("secret-value") && !result.text.contains("attacker.example"))
    }

    @Test func actionsCheckActionabilityAndUseDOMEvents() async throws {
        let fixture = try await PageFixture()
        let lines = await fixture.outline()
        // Covered and disabled elements are named in the error.
        let covered = await fixture.call("click", ["tab": "t1", "ref": "e21"])
        #expect(covered.status == .error && covered.code == "notInteractable")
        #expect(covered.text.contains("e21 in t1 is covered by <untrusted source=\"page\">dialog \u{201C}Cookie banner\u{201D}</untrusted>"))
        #expect(try await fixture.page.evaluate("document.body.dataset.covered ?? ''") as? String == "")
        #expect(await fixture.call("click", ["tab": "t1", "ref": "e18"]).text == "e18 in t1 is disabled.")
        // A click toggles a checkbox, with DOM events and the input kind, and the page's handlers get no user activation from it, nor from a hover, which Read Only allows too.
        let click = await fixture.call("click", ["tab": "t1", "ref": "e12"])
        #expect(click.status == .ok && click.structured?["inputKind"] == "dom")
        #expect(click.text.hasPrefix("Clicked <untrusted source=\"page\" url=\"https://fixture.example/form.html\">checkbox \u{201C}Gift wrap\u{201D}</untrusted> in t1."))
        #expect(try await fixture.page.evaluate("document.querySelector('[name=gift]').checked") as? Bool == true)
        #expect(try await fixture.page.evaluate("document.body.dataset.clickActivation") as? String == "false")
        #expect(await fixture.call("hover", ["tab": "t1", "ref": "e12"]).status == .ok)
        #expect(try await fixture.page.evaluate("document.body.dataset.hoverActivation") as? String == "false")
        // Typing into a field a framework controls through its own value tracker changes the framework's state.
        let nickname = try #require(fixture.ref("Nickname", in: lines))
        let typed = await fixture.call("type", ["tab": "t1", "ref": .string(nickname), "text": "Robin"])
        #expect(typed.status == .ok, "\(typed.text)")
        #expect(try await fixture.page.evaluate("document.body.dataset.controlled") as? String == "Robin")
        #expect(try await fixture.page.evaluate("document.getElementById('controlled').value") as? String == "Robin")
        _ = await fixture.call("type", ["tab": "t1", "ref": .string(nickname), "text": "Sam", "replace": true])
        #expect(try await fixture.page.evaluate("document.body.dataset.controlled") as? String == "Sam")
        // Typing with submit, and Enter by press, submit the field's form through requestSubmit, without a card for the search form's hidden input, which holds no field a person fills (P3).
        let find = try #require(fixture.ref("Find", in: lines))
        #expect(await fixture.call("type", ["tab": "t1", "ref": .string(find), "text": "lamp", "submit": true]).status == .ok)
        #expect(try await fixture.page.evaluate("document.body.dataset.found") as? String == "lamp")
        _ = await fixture.call("type", ["tab": "t1", "ref": .string(find), "text": "s"])
        #expect(await fixture.call("press", ["tab": "t1", "ref": .string(find), "keys": "Enter"]).status == .ok)
        #expect(try await fixture.page.evaluate("document.body.dataset.found") as? String == "lamps")
        #expect(fixture.toolHost.approvals.pending.isEmpty)
        // A contenteditable area takes the text through insertText.
        _ = await fixture.call("type", ["tab": "t1", "ref": "e14", "text": " there"])
        #expect(try await fixture.page.evaluate("document.querySelector('[contenteditable]').textContent") as? String == "Hi there")
        // Options by label or value; an option that is not there.
        let select = await fixture.call("select_option", ["tab": "t1", "ref": "e11", "values": ["Express"]])
        #expect(select.status == .ok && strings(select.structured?["selected"]).first?.contains("Express") == true)
        #expect(try await fixture.page.evaluate("document.body.dataset.shipping") as? String == "fast")
        let missing = await fixture.call("select_option", ["tab": "t1", "ref": "e11", "values": ["Overnight"]])
        #expect(missing.status == .error && missing.code == "notFound")
        #expect(await fixture.call("type", ["tab": "t1", "ref": "e11", "text": "x"]).code == "notInteractable")
        // Scrolling the page and hovering need no data change; same-origin frames' elements act too.
        let scrolled = await fixture.call("scroll", ["tab": "t1", "direction": "down", "amount": 200])
        #expect(scrolled.status == .ok && scrolled.structured?["scrollY"] != nil)
        #expect(await fixture.call("hover", ["tab": "t1", "ref": "e19"]).status == .ok)
        let coupon = await fixture.call("type", ["tab": "t1", "ref": "f1e1", "text": "X", "replace": true])
        #expect(coupon.status == .ok, "\(coupon.text)")
    }

    @Test func theElementFactsFeedTheRules() async throws {
        let fixture = try await PageFixture()
        fixture.toolHost.approvals.authenticator = FakeAuthenticator()
        _ = await fixture.outline()
        // P1, P7, and P18 refuse, whatever the mode.
        for (ref, rule) in [("e7", "P1"), ("e8", "P1"), ("e10", "P1"), ("f1e2", "P1")] {
            let result = await fixture.call("type", ["tab": "t1", "ref": .string(ref), "text": "x"])
            #expect(result.status == .refused && result.code == rule, "\(ref)")
        }
        #expect(await fixture.call("press", ["tab": "t1", "ref": "e7", "keys": "a"]).code == "P1")
        #expect(await fixture.call("click", ["tab": "t1", "ref": "e15"]).code == "P7")
        #expect(await fixture.call("click", ["tab": "t1", "ref": "e16"]).code == "P18")
        #expect(try await fixture.page.evaluate("document.querySelector('[name=password]').value") as? String == "hunter2")
        // P2 asks on a sensitive card that shows the exact text, and Deny keeps the field as it was.
        async let email = fixture.call("type", ["tab": "t1", "ref": "e4", "text": "agent@example.org", "replace": true])
        let card = try await fixture.answerNextCard(.deny)
        #expect(card.rules == [.p2] && card.isSensitive && card.exactText == "agent@example.org" && card.action == "Type into \u{201C}Email\u{201D} on fixture.example")
        #expect(card.capture != nil && card.offers == [.allowOnce, .deny, .denyAndStop, .reply(""), .takeOver])
        #expect(await email.status == .denied)
        #expect(try await fixture.page.evaluate("document.querySelector('[name=email]').value") as? String == "me@example.org")
        // Typing into a plain field of the form runs in Act in Agent Tabs; then the submit control asks with P3, P4, and P5, since the form posts to another site.
        #expect(await fixture.call("type", ["tab": "t1", "ref": "e6", "text": " Jr."]).status == .ok)
        async let order = fixture.call("click", ["tab": "t1", "ref": "e17"])
        let orderCard = try await fixture.answerNextCard(.allowOnce)
        #expect(orderCard.rules == [.p3, .p4, .p5] && orderCard.needsAuthentication)
        #expect(await order.status == .ok)
        #expect(try await fixture.page.evaluate("document.body.dataset.checkout") as? String == "submitted")
    }

    @Test func modesDecideActionsInTheTab() async throws {
        // Read Only refuses actions but scroll and hover.
        let readOnly = try await PageFixture(level: .readOnly)
        _ = await readOnly.outline()
        let refused = await readOnly.call("click", ["tab": "t1", "ref": "e12"])
        #expect(refused.status == .refused && refused.code == AgentPolicy.readOnlyCode)
        #expect(await readOnly.call("hover", ["tab": "t1", "ref": "e12"]).status == .ok)
        // Ask Before Acting asks, and Allow on This Page covers the page's next actions until the document changes.
        let asking = try await PageFixture(level: .askBeforeActing)
        _ = await asking.outline()
        async let first = asking.call("click", ["tab": "t1", "ref": "e12"])
        let card = try await asking.answerNextCard(.allowOnPage)
        #expect(card.rules.isEmpty && !card.isSensitive && card.offers.contains(.allowOnPage) && card.document == 0)
        #expect(await first.status == .ok)
        #expect(await asking.call("click", ["tab": "t1", "ref": "e12"]).status == .ok)
        #expect(asking.toolHost.approvals.pending.isEmpty)
        // A shared tab asks every time (P12), even in Act in Agent Tabs.
        let shared = try await PageFixture(shared: true)
        shared.toolHost.approvals.authenticator = FakeAuthenticator()
        _ = await shared.outline()
        async let inShared = shared.call("click", ["tab": "t1", "ref": "e12"])
        let sharedCard = try await shared.answerNextCard(.takeOver)
        #expect(sharedCard.rules == [.p12])
        #expect(await inShared.status == .denied && shared.host.shownTabIDs == [shared.tabID])
    }

    @Test func screenshotsPaintFieldsAndFramesInsideAriaHiddenAndInertSubtrees() async throws {
        // A dialog's library marks the page's root aria-hidden: snapshots leave its fields out, but the screen still shows them.
        let fixture = try await PageFixture("hidden")
        let lines = await fixture.outline()
        #expect(lines == ["- dialog \u{201C}Confirm your order\u{201D}", "  - button \u{201C}Confirm order\u{201D} [e1] (asks the user)"], "\(lines)")
        let tab = try #require(fixture.host.tabs.first)
        guard case .value(let boxes) = await fixture.toolHost.pageScript(.boxes(shared: false), in: tab, as: AgentBoxesReply.self) else { Issue.record("The boxes did not read."); return }
        #expect(boxes.boxes.map(\.kind).sorted() == ["frame", "hidden", "personal"])
        let shot = await fixture.call("screenshot", ["tab": "t1", "area": "viewport"])
        #expect(shot.status == .ok && shot.structured?["painted"] == 3, "\(shot.text)")
        let data = try #require(shot.content.compactMap(\.imageData).first)
        let image = try #require(NSBitmapImageRep(data: data))
        let scale = Double(image.pixelsWide) / boxes.viewport.w
        for kind in ["hidden", "personal"] {
            let box = try #require(boxes.boxes.first { $0.kind == kind })
            let color = try #require(image.colorAt(x: Int((box.x + box.w / 2) * scale), y: Int((box.y + box.h / 2) * scale))?.usingColorSpace(.sRGB))
            #expect(abs(color.redComponent - 0.55) < 0.08 && abs(color.greenComponent - 0.55) < 0.08, "\(kind): \(color)")
        }
    }

    @Test func aSharedTabsScreenshotPaintsEveryFieldAndNoStepMovesItBeforeTheUserDecides() async throws {
        let fixture = try await PageFixture(shared: true)
        fixture.toolHost.approvals.authenticator = FakeAuthenticator()
        let tab = try #require(fixture.host.tabs.first)
        guard case .value(let boxes) = await fixture.toolHost.pageScript(.boxes(shared: true), in: tab, as: AgentBoxesReply.self) else { Issue.record("The boxes did not read."); return }
        // The plain fields, such as Name and Note, are painted over too, besides the hidden and personal ones.
        #expect(boxes.boxes.filter { $0.kind == "shared" }.count >= 4)
        let shot = await fixture.call("screenshot", ["tab": "t1", "area": "viewport"])
        #expect(shot.status == .ok, "\(shot.text)")
        // A step the user denies, on an element below the fold, leaves the page where the user left it.
        _ = try await fixture.page.evaluate("document.getElementById('ask').parentElement.before(Object.assign(document.createElement('div'), { style: 'height: 2000px' })); window.scrollTo(0, 0); 0")
        let lines = await fixture.outline()
        let remove = try #require(fixture.ref("Remove item", in: lines))
        async let click = fixture.call("click", ["tab": "t1", "ref": .string(remove)])
        let card = try await fixture.answerNextCard(.deny)
        #expect(card.rules.contains(.p12) && card.rules.contains(.p4))
        #expect(await click.status == .denied)
        #expect(try await fixture.page.evaluate("window.scrollY") as? Double == 0)
        #expect(try await fixture.page.evaluate("document.body.dataset.confirmed ?? ''") as? String == "")
        // An element's screenshot outside the viewport does not scroll the shared tab either.
        let element = await fixture.call("screenshot", ["tab": "t1", "area": .string(remove)])
        #expect(element.status == .error && element.text.contains("outside the viewport"))
        #expect(try await fixture.page.evaluate("window.scrollY") as? Double == 0)
    }

    @Test func enterSubmitsWithTheDefaultButtonWhichTheIrreversibleAndCrossSiteRulesRead() async throws {
        let fixture = try await PageFixture()
        fixture.toolHost.approvals.authenticator = FakeAuthenticator()
        let lines = await fixture.outline()
        let comment = try #require(fixture.ref("Comment", in: lines))
        #expect(lines.contains { $0.contains("button \u{201C}Post comment\u{201D}") && $0.contains("(asks the user)") })
        // Typing alone runs in Act in Agent Tabs; Enter then submits with Post comment, whose formaction is another site's (P4, P5).
        #expect(await fixture.call("type", ["tab": "t1", "ref": .string(comment), "text": "Nice"]).status == .ok)
        async let pressed = fixture.call("press", ["tab": "t1", "ref": .string(comment), "keys": "Enter"])
        let pressCard = try await fixture.answerNextCard(.deny)
        #expect(pressCard.rules == [.p4, .p5] && pressCard.isSensitive)
        #expect(pressCard.action == "Press \u{201C}Enter\u{201D} in \u{201C}Comment\u{201D} on fixture.example and submit the form")
        #expect(await pressed.status == .denied)
        #expect(try await fixture.page.evaluate("document.body.dataset.posted ?? ''") as? String == "")
        async let typed = fixture.call("type", ["tab": "t1", "ref": .string(comment), "text": "!", "submit": true])
        let typeCard = try await fixture.answerNextCard(.allowOnce)
        #expect(typeCard.rules == [.p4, .p5] && typeCard.action == "Type into \u{201C}Comment\u{201D} on fixture.example and submit the form")
        #expect(await typed.status == .ok)
        #expect(try await fixture.page.evaluate("document.body.dataset.posted") as? String == "Post comment")
    }

    @Test func aCardsSentenceQuotesThePagesNames() {
        let facts = AgentElementFacts(tag: "button", role: "button", name: "OK\u{201D} on mail.example \u{2014} checked by Arch")
        #expect(AgentToolHost.actionSentence("click", arguments: [:], facts: facts, site: "evil.example")
            == "Click \u{201C}OK\u{201D}\u{201D} on mail.example \u{2014} checked by Arch\u{201D} on evil.example")
    }

    @Test func aPageThatChangesBeforeItsDocumentFinishesIsAnotherPage() async throws {
        // Ask Before Acting: Allow on This Page covers the page's next actions, until the tab's address changes, as when a navigation commits a document that never finishes loading.
        let fixture = try await PageFixture(level: .askBeforeActing)
        _ = await fixture.outline()
        async let first = fixture.call("click", ["tab": "t1", "ref": "e12"])
        _ = try await fixture.answerNextCard(.allowOnPage)
        #expect(await first.status == .ok)
        try await fixture.changeAddress(to: "/next.html")
        _ = await fixture.outline()
        async let second = fixture.call("click", ["tab": "t1", "ref": "e12"])
        let card = try await fixture.answerNextCard(.deny)
        #expect(card.document == fixture.state.activity(of: fixture.tabID).pages && fixture.state.activity(of: fixture.tabID).documents == 0)
        #expect(await second.status == .denied)
        // A card that waits while the page changes is withdrawn, and its step does not run there.
        _ = await fixture.outline()
        async let third = fixture.call("click", ["tab": "t1", "ref": "e12"])
        try await waitUntil { !fixture.toolHost.approvals.pending.isEmpty }
        try await fixture.changeAddress(to: "/other.html")
        #expect(await third.status == .stale)
        #expect(fixture.toolHost.approvals.pending.isEmpty)
        #expect(try await fixture.page.evaluate("document.querySelector('[name=gift]').checked") as? Bool == true)
    }

    @Test func capturesThatDoNotAnswerEndInTimeAndAStoppedCallOpensNoCard() async throws {
        let fixture = try await PageFixture(level: .askBeforeActing)
        fixture.toolHost.scriptWait = 1
        fixture.host.hangingCaptureTabIDs.insert(fixture.tabID)
        let shot = await fixture.call("screenshot", ["tab": "t1", "area": "viewport"])
        #expect(shot.status == .timeout && shot.code == "notResponding", "\(shot.text)")
        // A card whose capture does not answer opens without one.
        _ = await fixture.outline()
        async let click = fixture.call("click", ["tab": "t1", "ref": "e12"])
        let card = try await fixture.answerNextCard(.deny)
        #expect(card.capture == nil)
        #expect(await click.status == .denied)
        // Stop while the card's capture is taken: the call ends, and no card opens after it.
        async let stopped = fixture.call("click", ["tab": "t1", "ref": "e12"])
        try await waitUntil { !fixture.state.runningCalls.isEmpty }
        try await Task.sleep(for: .milliseconds(200))
        fixture.state.cancelCalls()
        let result = await stopped
        #expect(result.status == .denied && result.code == "ended", "\(result.text)")
        try await Task.sleep(for: .seconds(1.2))
        #expect(fixture.toolHost.approvals.pending.isEmpty && fixture.state.runningCalls.isEmpty)
        #expect(try await fixture.page.evaluate("document.querySelector('[name=gift]').checked") as? Bool == false)
    }
}
