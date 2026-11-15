// The agents' page script (docs/agents.md, Page snapshots and refs): one JavaScript function written for Arch, which the host runs with an operation object through `executeJavaScript(_:inWorld:completion:)` in the world `arch.agent` and which answers with JSON text. WebKit runs it in a content world of its own; Chromium runs every world in the page's main world, where a page can replace the built-ins it calls (Risks 2). It keeps nothing in the page between calls (agent decision 13): a ref is an element's index in the script's walk, and the host keeps each ref's fingerprint with the document's address, so that an action walks again and fails as stale when the element at that index differs. Only the target check of trusted input (`targetCheck`) holds state, one action's check from `prepare` until the action's events have come. The walk follows open shadow roots and same-origin frames, lists other sites' frames without reading them, and leaves out extension frames, hidden elements, `aria-hidden` and `inert` subtrees, and scripts; the boxes that screenshots paint over come from every subtree that shows on the screen. A field whose value is secret (P1's class) or personal never gives its value, nor any field of a tab the user shared, where screenshots paint every field over.
import AgentControl
import ARCHEngine
import Foundation

/// The class of a field's value: a hidden value never leaves the page; a personal one shows as `<personal>`.
public enum AgentValueClass: String, Codable, Sendable {
    case hidden
    case personal
}

/// A kind of field in an element's form, which P3 reads.
public enum AgentFormFieldKind: String, Codable, Sendable {
    case password
    case oneTimeCode
    case payment
    case personal
}

/// An element's box in CSS pixels, relative to the main frame's viewport.
public struct AgentBox: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// What the script reports about one element, which the policy reads (docs/agents.md, Page snapshots and refs ▸ Actions).
public struct AgentElementFacts: Codable, Equatable, Sendable {
    public var tag: String
    public var role: String
    /// The element's reduced accessible name, at most 80 characters; a field's value never joins it.
    public var name: String
    public var inputType: String?
    public var autocomplete: String?
    public var valueClass: AgentValueClass?
    /// A button's own value, such as an `<input type=submit>`'s, which P4 reads beside the name; never a field's text.
    public var value: String?
    public var isEditable: Bool
    public var isFileInput: Bool
    public var isSelect: Bool
    public var submitsForm: Bool
    /// Names the element's form within the document, so that the host can tell which forms the session typed into (P5).
    public var formKey: String?
    public var formFields: [AgentFormFieldKind]
    /// The host the form sends to: a submit control's own `formaction` when it has one, and for a field the `formaction` of the button that Enter submits with, else the form's action.
    public var formActionHost: String?
    /// For a field of a form, the name and value of the button that Enter submits the form with, its first enabled submit button, which P4 reads for a submission by Enter.
    public var submitterName: String?
    public var submitterValue: String?
    public var box: AgentBox?

    public init(tag: String, role: String, name: String, inputType: String? = nil, autocomplete: String? = nil, valueClass: AgentValueClass? = nil, value: String? = nil,
                isEditable: Bool = false, isFileInput: Bool = false, isSelect: Bool = false, submitsForm: Bool = false, formKey: String? = nil, formFields: [AgentFormFieldKind] = [],
                formActionHost: String? = nil, submitterName: String? = nil, submitterValue: String? = nil, box: AgentBox? = nil) {
        self.tag = tag
        self.role = role
        self.name = name
        self.inputType = inputType
        self.autocomplete = autocomplete
        self.valueClass = valueClass
        self.value = value
        self.isEditable = isEditable
        self.isFileInput = isFileInput
        self.isSelect = isSelect
        self.submitsForm = submitsForm
        self.formKey = formKey
        self.formFields = formFields
        self.formActionHost = formActionHost
        self.submitterName = submitterName
        self.submitterValue = submitterValue
        self.box = box
    }
}

/// A ref as the script reads it: the frame (0 for the main frame, then same-origin frames in walk order) and the element's index there, with the fingerprint the snapshot gave.
public struct AgentRefTarget: Codable, Equatable, Sendable {
    public var frame: Int
    public var index: Int
    public var fingerprint: String

    /// Reads `e5` or `f1e3`; nil for anything else.
    public init?(_ ref: String, fingerprint: String = "") {
        let pattern = #"^(?:f([1-9][0-9]*))?e([1-9][0-9]*)$"#
        guard let match = ref.firstMatch(of: try! Regex(pattern)), let index = match[2].substring.flatMap({ Int($0) }) else { return nil }
        frame = match[1].substring.flatMap { Int($0) } ?? 0
        self.index = index
        self.fingerprint = fingerprint
    }

    public var ref: String { frame == 0 ? "e\(index)" : "f\(frame)e\(index)" }
}

/// What the host asks the script.
enum AgentPageOperation: Encodable {
    /// The outline: `interactive` or `full`, optionally only the subtree of `ref`, without any field's value in a shared tab.
    case snapshot(full: Bool, ref: AgentRefTarget?, shared: Bool)
    /// The facts of an element, or of the focused element without a ref, and whether an action can reach it. With `scroll`, it scrolls into view first and must be on top at its center; without, the page stays where it is and only a detached, hidden, or disabled element is named.
    case element(AgentRefTarget?, scroll: Bool)
    /// The boxes a screenshot paints over, file inputs that hold files among them, and the viewport and page sizes; in a tab the user shared, every field's box too.
    case boxes(shared: Bool)
    case act(AgentPageAction)
    /// Before trusted input (VII.21): the element as `act` checks it, a field focused with its selection placed for `type`, the point to act at with the visual viewport, and the target check armed for the input's events.
    case prepare(AgentInputPreparation)
    /// What the target check saw of the input's events, with the page's scroll position; `need` replaces the counts that mark the input's end, `cancelRest` cancels the input's events still to come, and `disarm` ends the check. A check whose counts are reached ends by itself.
    case inputState(need: AgentInputNeed?, cancelRest: Bool, disarm: Bool)

    private enum Keys: String, CodingKey { case op, full, ref, shared, scroll, action, words, need, cancelRest, disarm }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(AgentPageScripts.words, forKey: .words)
        switch self {
        case .snapshot(let full, let ref, let shared):
            try container.encode("snapshot", forKey: .op)
            try container.encode(full, forKey: .full)
            try container.encodeIfPresent(ref, forKey: .ref)
            try container.encode(shared, forKey: .shared)
        case .element(let ref, let scroll):
            try container.encode("element", forKey: .op)
            try container.encodeIfPresent(ref, forKey: .ref)
            try container.encode(scroll, forKey: .scroll)
        case .boxes(let shared):
            try container.encode("boxes", forKey: .op)
            try container.encode(shared, forKey: .shared)
        case .act(let action):
            try container.encode("act", forKey: .op)
            try container.encode(action, forKey: .action)
        case .prepare(let preparation):
            try container.encode("prepare", forKey: .op)
            try container.encode(preparation, forKey: .action)
        case .inputState(let need, let cancelRest, let disarm):
            try container.encode("inputState", forKey: .op)
            try container.encodeIfPresent(need, forKey: .need)
            try container.encode(cancelRest, forKey: .cancelRest)
            try container.encode(disarm, forKey: .disarm)
        }
    }
}

/// What `prepare` readies for trusted input.
struct AgentInputPreparation: Encodable, Equatable {
    /// `click`, `hover`, `type`, `press`, or `scroll`; a `scroll` without a ref arms no check.
    var kind: String
    var ref: AgentRefTarget?
    /// For `type`: select the field's text, which the input replaces, instead of placing the caret at its end.
    var replace: Bool?
    /// For `press` without a ref: the focused element the policy classified the step by, which must still have focus; nil when no element had focus.
    var focus: AgentFocusedElement?
    /// The events whose target the check checks, and `keyup`, which it only counts, since a key's own default action, such as Tab's, moves focus before it.
    var kinds: [String]
    var need: AgentInputNeed
    /// How long the check stays armed, in milliseconds.
    var holdMs: Int
}

/// The focused element as the policy read it.
struct AgentFocusedElement: Encodable, Equatable {
    var tag: String
    var role: String
    var name: String

    init(_ facts: AgentElementFacts) {
        tag = facts.tag
        role = facts.role
        name = facts.name
    }
}

/// The counts of the target check after which an input's events have all come: clicks, key ups, moves, and the length of the text that `beforeinput` events carry.
struct AgentInputNeed: Codable, Equatable {
    var clicks: Int?
    var keyups: Int?
    var moves: Int?
    var text: Int?
}

/// The page's visual viewport in CSS pixels of the layout viewport, with its pinch zoom.
struct AgentVisualViewport: Decodable, Equatable {
    var left: Double
    var top: Double
    var scale: Double
    var w: Double
    var h: Double
}

struct AgentPoint: Decodable, Equatable {
    var x: Double
    var y: Double
}

/// What `prepare` reports.
struct AgentInputReply: Decodable {
    var url: String
    /// Why the input cannot go: `act`'s problems; `stale` when focus is on another element than the one the step is for; and `noCheck` (no target check in the document), `inFrame` (focus inside a frame), `noFocus` (the element takes no focus), `noSelection` (a field without a selection to place), and `readOnly` (a read-only field), for which the action uses DOM events.
    var problem: String?
    var cover: String?
    var hit: String?
    /// The element's center in CSS pixels of the layout viewport.
    var point: AgentPoint?
    var viewport: AgentVisualViewport
    /// Whether the element that receives keys takes text.
    var editable: Bool?
}

/// What the target check saw.
struct AgentInputState: Decodable {
    var url: String
    /// False once the check ended, timed out, or was never armed in this document, as after the input loaded another.
    var armed: Bool
    var seen: Int
    var cancelled: Bool
    var complete: Bool
    var scrollX: Double
    var scrollY: Double
}

/// An action as the script performs it through DOM events (agent decision 7).
struct AgentPageAction: Encodable, Equatable {
    var kind: String
    var ref: AgentRefTarget?
    var text: String?
    var replace: Bool?
    var submit: Bool?
    var keys: String?
    var values: [String]?
    var count: Int?
    var modifiers: [String]?
    var direction: String?
    var amount: Int?
}

/// One line of the outline as the script reports it; the host writes the line and adds the policy's annotations.
struct AgentOutlineNode: Decodable, Equatable {
    var depth: Int
    var role: String
    var name: String?
    var ref: String?
    var fingerprint: String?
    /// A field's value, never for the hidden and personal classes or in a shared tab.
    var value: String?
    var valueClass: AgentValueClass?
    var level: Int?
    var checked: Bool?
    var disabled: Bool?
    /// A link's full address, which the host keeps and shows reduced.
    var href: String?
    var submits: Bool?
    var formFields: [AgentFormFieldKind]?
    var inputType: String?
    var isEditable: Bool?
    var isFileInput: Bool?
    /// Another site's frame, listed and not read, with its address.
    var otherSite: Bool?
    var frameURL: String?
    /// Full mode's visible text.
    var text: String?
}

struct AgentSnapshotReply: Decodable {
    var url: String
    var title: String
    var nodes: [AgentOutlineNode]
    /// The ref that `snapshot`'s `ref` named is gone or no longer the same element.
    var stale: Bool?
}

/// An element's facts, or why an action cannot reach it.
struct AgentElementReply: Decodable {
    var url: String
    var facts: AgentElementFacts?
    /// `stale`, `notFound`, `hidden`, `disabled`, `covered`, `offscreen`, or `detached`.
    var problem: String?
    /// The element on top of it, as `button "Accept cookies"`.
    var cover: String?
    var viewport: AgentSize?
}

struct AgentSize: Codable, Equatable {
    var w: Double
    var h: Double
}

struct AgentBoxesReply: Decodable, Equatable {
    struct Box: Decodable, Equatable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        /// `hidden`, `personal`, `frame` (another site's), `extension`, `shared` (any other field of a tab the user shared), or `file` (a file input that holds files, whose control shows their names).
        var kind: String
    }

    var url: String
    var viewport: AgentSize
    var page: AgentSize
    var scrollX: Double
    var scrollY: Double
    var boxes: [Box]
}

struct AgentActionReply: Decodable {
    var url: String
    var problem: String?
    var cover: String?
    /// What the action reached, as `button "Next"`.
    var hit: String?
    var selected: [String]?
    var scrollX: Double?
    var scrollY: Double?
    var missing: String?
}

public enum AgentPageScripts {
    /// The script world of the agents' page script.
    static let world = "arch.agent"

    /// The global through which `prepare` arms the target check and `inputState` reads it.
    static let targetCheckName = "__archAgentInput"

    /// The target check of trusted input (docs/agents.md, Actions), which `Browsing` gives agent tabs' main frames at document start in the world `arch.agent`, so that its capture-phase listeners on the window come before any of the page's. While `prepare` has it armed, it cancels with `preventDefault()` and `stopImmediatePropagation()` each trusted event of the action's kinds whose target is not the element, or inside it, or a label of it, and every later one of the action, and counts what came. A `keyup` it only counts and cancels after an earlier cancel, since the key's own default action, such as Tab's, moves focus before it. It holds the built-ins it calls from document start. On WebKit the page cannot see its world; on Chromium it shares the page's main world, where the page can find and change the check (Risks 19).
    public static let targetCheck = EnginePageScript(world: world, source: targetCheckSource, injectionTime: .documentStart, mainFrameOnly: true)

    static let targetCheckSource = #"""
    (channel) => {
      "use strict";
      if (Object.getOwnPropertyDescriptor(globalThis, "\#(targetCheckName)")) return;
      const apply = Reflect.apply, describe = Object.getOwnPropertyDescriptor, define = Object.defineProperty, freeze = Object.freeze, create = Object.create;
      const listen = EventTarget.prototype.addEventListener, now = Performance.prototype.now, clock = performance;
      const pathOf = Event.prototype.composedPath, cancel = Event.prototype.preventDefault, stop = Event.prototype.stopImmediatePropagation;
      const typeOf = describe(Event.prototype, "type").get, dataOf = describe(InputEvent.prototype, "data").get;
      const parentOf = describe(Node.prototype, "parentNode").get, hostOf = describe(ShadowRoot.prototype, "host").get;
      const localNameOf = describe(Element.prototype, "localName").get, controlOf = describe(HTMLLabelElement.prototype, "control").get;
      const rootOf = describe(Document.prototype, "documentElement").get;
      const KINDS = ["pointerover", "mouseover", "pointerdown", "mousedown", "pointerup", "mouseup", "click", "dblclick", "pointermove", "mousemove",
        "keydown", "keypress", "keyup", "beforeinput"];
      const doc = document;
      let state = null;
      const call = (getter, node) => { try { return apply(getter, node, []); } catch (error) { return null; } };
      const up = (node) => call(parentOf, node) || call(hostOf, node);
      const within = (target, element) => {
        for (let node = target; node; node = up(node)) {
          if (node === element) return true;
          if (call(localNameOf, node) === "label" && call(controlOf, node) === element) return true;
        }
        return false;
      };
      const accepts = (current, target) => current.exact ? target === current.element || target === doc || target === call(rootOf, doc) : within(target, current.element);
      const listener = (event) => {
        const current = state;
        if (!current || current.done || !event.isTrusted) return;
        if (apply(now, clock, []) > current.until) { current.done = true; return; }
        const type = apply(typeOf, event, []);
        if (!current.kinds[type]) return;
        current.seen += 1;
        if (!current.cancelled && type !== "keyup" && !accepts(current, apply(pathOf, event, [])[0])) current.cancelled = true;
        if (current.cancelled) {
          apply(cancel, event, []);
          apply(stop, event, []);
        }
        if (type === "click") current.clicks += 1;
        else if (type === "keyup") current.keyups += 1;
        else if (type === "keypress") current.keypresses += 1;
        else if (type === "mousemove") current.moves += 1;
        else if (type === "beforeinput") {
          const data = apply(dataOf, event, []);
          if (typeof data === "string") current.text += data.length;
        }
      };
      for (let index = 0; index < KINDS.length; index += 1) apply(listen, window, [KINDS[index], listener, true]);
      const complete = (current) => {
        const need = current.need;
        // Text comes as one `beforeinput`, or on Chromium as a keypress per UTF-16 unit, whose `beforeinput` the same task dispatches.
        return (!need.clicks || current.clicks >= need.clicks) && (!need.keyups || current.keyups >= need.keyups) && (!need.moves || current.moves >= need.moves)
          && (!need.text || current.text >= need.text || current.keypresses >= need.text);
      };
      define(globalThis, "\#(targetCheckName)", { value: freeze({
        arm(element, exact, kinds, need, holdMs) {
          const set = create(null);
          for (let index = 0; index < kinds.length; index += 1) set[kinds[index]] = true;
          state = { element, exact, kinds: set, need: { clicks: need.clicks, keyups: need.keyups, moves: need.moves, text: need.text }, until: apply(now, clock, []) + holdMs,
            done: false, seen: 0, cancelled: false, clicks: 0, keyups: 0, keypresses: 0, moves: 0, text: 0 };
        },
        read(need, cancelRest, disarm) {
          const current = state;
          if (!current) return { armed: false, seen: 0, cancelled: false, complete: false };
          if (need) current.need = { clicks: need.clicks, keyups: need.keyups, moves: need.moves, text: need.text };
          if (cancelRest) current.cancelled = true;
          if (apply(now, clock, []) > current.until) current.done = true;
          const reply = { armed: !current.done, seen: current.seen, cancelled: current.cancelled, complete: complete(current) };
          if (disarm || reply.complete) state = null;
          return reply;
        },
      }) });
    }
    """#

    /// The lists the script reads, from the policy, so that one copy of each exists.
    struct Words: Encodable {
        var secret = AgentPolicy.secretWords
        var hiddenAutocomplete = AgentPolicy.hiddenAutocomplete
        var hiddenAutocompletePrefix = AgentPolicy.hiddenAutocompletePrefix
        var personalAutocomplete = AgentPolicy.personalAutocomplete
    }

    static let words = Words()

    /// The function expression for one operation: the operation as a JSON literal, then the script.
    static func source(for operation: AgentPageOperation) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(operation)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "(channel) => {\nconst op = \(json);\n\(body)\n}"
    }

    /// The script's body, which ends by returning the reply as JSON text. Keep it free of state kept in the page, which on Chromium the page could reach; the target check alone keeps an action's check.
    static let body = #"""
    "use strict";
    const MAX_NAME = 80, MAX_VALUE = 200, MAX_TEXT = 200;
    // The extension schemes of Arch's two engines.
    const EXTENSION = /^(chrome|webkit)-extension:/i;
    // A form's named fields shadow its own properties, as a field named "action" does `form.action`, so the form's action and fields are read through the prototype's getters.
    const FORM_ACTION = Object.getOwnPropertyDescriptor(HTMLFormElement.prototype, "action").get;
    const FORM_ELEMENTS = Object.getOwnPropertyDescriptor(HTMLFormElement.prototype, "elements").get;
    const SKIPPED = new Set(["script", "style", "template", "noscript", "head", "meta", "link", "title"]);
    const INTERACTIVE = new Set(["link", "button", "textbox", "searchbox", "checkbox", "radio", "combobox", "listbox", "slider", "spinbutton", "switch", "tab", "menuitem",
      "menuitemcheckbox", "menuitemradio", "option", "treeitem", "gridcell"]);
    const LANDMARKS = new Set(["banner", "navigation", "main", "contentinfo", "complementary", "region", "search", "form", "dialog", "alertdialog"]);
    const NAMED_BY_CONTENT = new Set(["link", "button", "heading", "option", "tab", "menuitem", "menuitemcheckbox", "menuitemradio", "checkbox", "radio", "switch", "treeitem",
      "gridcell", "cell"]);
    const TEXT_TYPES = new Set(["text", "email", "tel", "url", "search", "password", "number", "date", "datetime-local", "month", "time", "week", ""]);
    const words = op.words;

    const normalized = (text) => String(text || "").replace(/([a-z])([A-Z])/g, "$1 $2").replace(/([A-Za-z])([0-9])/g, "$1 $2").replace(/([0-9])([A-Za-z])/g, "$1 $2")
      .toLowerCase().replace(/[^\p{L}\p{N}']+/gu, " ").trim();
    const namesOneOf = (text, list) => {
      const t = " " + normalized(text) + " ";
      return list.some((word) => /^[\x00-\x7f]*$/.test(word) ? t.includes(" " + word.toLowerCase() + " ") : t.includes(word.toLowerCase()));
    };
    const cut = (text, length) => {
      const t = String(text || "").replace(/\s+/g, " ").trim();
      return t.length > length ? t.slice(0, length - 1) + "…" : t;
    };
    const windowOf = (el) => el.ownerDocument.defaultView;
    /// Scrolls at once, whatever the page's `scroll-behavior`, so that boxes read afterward are final.
    const scrollIntoView = (el) => {
      try { el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" }); } catch (error) { el.scrollIntoView({ block: "center", inline: "center" }); }
    };
    const styleOf = (el) => windowOf(el).getComputedStyle(el);
    const tagOf = (el) => el.localName;
    const typeOf = (el) => tagOf(el) === "input" ? (el.getAttribute("type") || "text").toLowerCase() : null;

    function isVisible(el) {
      const style = styleOf(el);
      if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return false;
      for (const rect of el.getClientRects()) if (rect.width > 0 || rect.height > 0) return true;
      return false;
    }

    function isEditable(el) {
      const tag = tagOf(el);
      if (tag === "textarea") return true;
      if (tag === "input") return TEXT_TYPES.has(typeOf(el));
      return el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable);
    }

    function roleOf(el) {
      const explicit = (el.getAttribute("role") || "").trim().split(/\s+/)[0].toLowerCase();
      if (explicit && !["none", "presentation", "generic"].includes(explicit)) return explicit;
      const tag = tagOf(el);
      switch (tag) {
        case "a": case "area": return el.hasAttribute("href") ? "link" : null;
        case "button": case "summary": return "button";
        case "select": return el.multiple || el.size > 1 ? "listbox" : "combobox";
        case "textarea": return "textbox";
        case "input": {
          const type = typeOf(el);
          if (type === "hidden") return null;
          const roles = { button: "button", submit: "button", reset: "button", image: "button", file: "button", color: "button", checkbox: "checkbox", radio: "radio",
            range: "slider", number: "spinbutton", search: "searchbox" };
          return roles[type] || "textbox";
        }
        case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": return "heading";
        case "nav": return "navigation";
        case "main": return "main";
        case "aside": return "complementary";
        case "dialog": return "dialog";
        case "header": case "footer": return el.closest("article, aside, main, nav, section") ? null : (tag === "header" ? "banner" : "contentinfo");
        case "form": return nameOf(el, "form") ? "form" : null;
        case "section": return nameOf(el, "region") ? "region" : null;
        case "img": return el.getAttribute("alt") ? "img" : null;
      }
      if (isEditable(el)) return "textbox";
      return null;
    }

    function textOf(node, skip) {
      let text = "";
      const visit = (n) => {
        if (n.nodeType === 3) { text += n.data; return; }
        if (n.nodeType !== 1 || n === skip) return;
        const tag = tagOf(n);
        if (SKIPPED.has(tag) || ["input", "select", "textarea"].includes(tag) || n.getAttribute("aria-hidden") === "true") return;
        if (tag === "img") { text += " " + (n.getAttribute("alt") || "") + " "; return; }
        if (styleOf(n).display === "none") return;
        const children = n.shadowRoot ? n.shadowRoot.childNodes : n.childNodes;
        for (const child of children) visit(child);
        if (styleOf(n).display !== "inline") text += " ";
      };
      for (const child of (node.shadowRoot ? node.shadowRoot.childNodes : node.childNodes)) visit(child);
      return text.replace(/\s+/g, " ").trim();
    }

    function nameOf(el, role) {
      const doc = el.ownerDocument;
      const labelledBy = el.getAttribute("aria-labelledby");
      if (labelledBy) {
        const text = labelledBy.split(/\s+/).map((id) => doc.getElementById(id)).filter(Boolean).map((l) => textOf(l)).join(" ").trim();
        if (text) return cut(text, MAX_NAME);
      }
      const label = el.getAttribute("aria-label");
      if (label && label.trim()) return cut(label, MAX_NAME);
      const tag = tagOf(el), type = typeOf(el);
      if (["input", "select", "textarea"].includes(tag) && el.labels && el.labels.length) {
        const text = Array.from(el.labels).map((l) => textOf(l, el)).join(" ").trim();
        if (text) return cut(text, MAX_NAME);
      }
      if (tag === "img" || type === "image") { const alt = el.getAttribute("alt"); if (alt) return cut(alt, MAX_NAME); }
      if (type === "submit" || type === "reset" || type === "button") return cut(el.getAttribute("value") || (type === "submit" ? "Submit" : type === "reset" ? "Reset" : ""), MAX_NAME);
      if (role && NAMED_BY_CONTENT.has(role)) { const text = textOf(el); if (text) return cut(text, MAX_NAME); }
      if (tag === "iframe" || tag === "frame") {
        const title = el.getAttribute("title") || el.getAttribute("name");
        if (title) return cut(title, MAX_NAME);
        try { if (el.contentDocument && el.contentDocument.title) return cut(el.contentDocument.title, MAX_NAME); } catch (error) {}
      }
      const title = el.getAttribute("title");
      if (title && title.trim()) return cut(title, MAX_NAME);
      const placeholder = el.getAttribute("placeholder");
      if (placeholder && placeholder.trim()) return cut(placeholder, MAX_NAME);
      return "";
    }

    /// The class of a field's value from its type, `autocomplete`, and the words of its label, name, ID, and placeholder.
    function valueClassOf(el, name) {
      const tag = tagOf(el), type = typeOf(el);
      if (!(["input", "textarea", "select"].includes(tag) || isEditable(el))) return null;
      if (type === "password" || type === "hidden") return "hidden";
      const tokens = (el.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/).filter(Boolean);
      if (tokens.some((t) => words.hiddenAutocomplete.includes(t) || t.startsWith(words.hiddenAutocompletePrefix))) return "hidden";
      const described = [name, el.getAttribute("name"), el.id, el.getAttribute("placeholder"), el.getAttribute("aria-label")].join(" ");
      if (namesOneOf(described, words.secret)) return "hidden";
      if (tokens.some((t) => words.personalAutocomplete.includes(t)) || type === "email" || type === "tel") return "personal";
      return null;
    }

    /// The kinds of the fields a person fills in a form, for P3: text fields, text areas, and selects, never hidden inputs or buttons, whose values no person types.
    function formFieldsOf(form) {
      const kinds = new Set();
      if (!form) return [];
      for (const field of FORM_ELEMENTS.call(form)) {
        const tag = tagOf(field), type = typeOf(field);
        if (!(tag === "textarea" || tag === "select" || (tag === "input" && TEXT_TYPES.has(type)))) continue;
        const tokens = (field.getAttribute("autocomplete") || "").toLowerCase().split(/\s+/);
        if (type === "password" || tokens.includes("current-password") || tokens.includes("new-password")) kinds.add("password");
        else if (tokens.includes("one-time-code")) kinds.add("oneTimeCode");
        else if (tokens.some((t) => t.startsWith(words.hiddenAutocompletePrefix))) kinds.add("payment");
        else {
          const cls = valueClassOf(field, nameOf(field, roleOf(field)));
          if (cls === "hidden") kinds.add(namesOneOf([field.getAttribute("name"), field.id, nameOf(field, null)].join(" "), ["card number", "credit card", "cvv", "cvc", "security code", "카드번호", "카드 번호"]) ? "payment" : "password");
          else if (cls === "personal") kinds.add("personal");
        }
      }
      return Array.from(kinds);
    }

    function submitsForm(el) {
      if (!el.form) return false;
      const tag = tagOf(el), type = typeOf(el);
      if (tag === "button") return (el.getAttribute("type") || "submit").toLowerCase() === "submit";
      return type === "submit" || type === "image";
    }

    /// The form's default button, which Enter in one of its fields submits with: its first submit button in tree order, enabled or not. Enter submits nothing while it is disabled.
    function defaultSubmitterOf(form) {
      if (!form) return null;
      return Array.from(FORM_ELEMENTS.call(form)).find((e) => submitsForm(e)) || null;
    }

    /// Where a submission goes: the submitter's own `formaction` when it has one, else the form's action.
    function actionOf(form, submitter) {
      return submitter && submitter.hasAttribute("formaction") ? submitter.formAction : FORM_ACTION.call(form);
    }

    function formKeyOf(el, frame) {
      const form = el.form;
      if (!form) return null;
      return frame + ":" + Array.prototype.indexOf.call(el.ownerDocument.forms, form);
    }

    function hostOf(address, base) {
      try { return new URL(address, base).host || null; } catch (error) { return null; }
    }

    function fingerprintOf(el, role, name) {
      return [tagOf(el), role, typeOf(el) || "", name.slice(0, 40)].join("|");
    }

    function describe(el) {
      const role = roleOf(el) || tagOf(el);
      const name = nameOf(el, role);
      return name ? role + " “" + name + "”" : role;
    }

    function childrenOf(node) {
      if (node.shadowRoot) return Array.from(node.shadowRoot.childNodes);
      if (node.localName === "slot") {
        const assigned = node.assignedNodes({ flatten: true });
        if (assigned.length) return assigned;
      }
      return Array.from(node.childNodes);
    }

    /// Walks the main frame's document and its same-origin frames in document order and calls the visitor's methods. Refs count the visible interactive elements of each frame from 1; frames count from 1 in the order the walk reaches them. Every operation that names refs walks the same way, so that a ref names the same element in each. `everyRendered` also enters `aria-hidden` and `inert` subtrees, which still show on the screen, for the boxes a screenshot paints over.
    function walk(visitor, everyRendered) {
      const counters = [0];
      const offsets = [{ x: 0, y: 0 }];
      const visit = (node, depth, frame, inRef) => {
        if (visitor.done) return;
        if (node.nodeType === 3) { if (visitor.text && !inRef) visitor.text(node, depth); return; }
        if (node.nodeType !== 1) return;
        const el = node, tag = tagOf(el);
        if (SKIPPED.has(tag) || (!everyRendered && (el.getAttribute("aria-hidden") === "true" || el.hasAttribute("inert")))) return;
        const style = styleOf(el);
        if (style.display === "none") return;
        if (tag === "iframe" || tag === "frame") {
          const src = el.getAttribute("src") || "";
          if (EXTENSION.test(src)) { if (visitor.extensionFrame) visitor.extensionFrame(el, frame, offsets[frame]); return; }
          let inner = null;
          try { inner = el.contentDocument; } catch (error) { inner = null; }
          if (inner && inner.documentElement && isVisible(el)) {
            const index = counters.length;
            counters.push(0);
            const rect = el.getBoundingClientRect();
            offsets.push({ x: offsets[frame].x + rect.left + el.clientLeft, y: offsets[frame].y + rect.top + el.clientTop });
            if (visitor.frame) visitor.frame(el, depth, frame, index);
            for (const child of childrenOf(inner.body || inner.documentElement)) visit(child, depth + 1, index, false);
          } else if (isVisible(el) && visitor.otherFrame) {
            visitor.otherFrame(el, depth, frame, offsets[frame]);
          }
          return;
        }
        const role = roleOf(el);
        let childDepth = depth, childInRef = inRef;
        const visible = isVisible(el);
        if (role && INTERACTIVE.has(role) && !(role === "option" && el.closest("select")) && visible) {
          counters[frame] += 1;
          if (visitor.ref) visitor.ref(el, role, depth, frame, counters[frame], offsets[frame]);
          if (visitor.done) return;
          childDepth = depth + 1;
          childInRef = true;
        } else if (role && (LANDMARKS.has(role) || role === "heading" || role === "img") && visible) {
          if (visitor.landmark) visitor.landmark(el, role, depth, frame);
          childDepth = depth + 1;
          childInRef = inRef || role === "heading";
        } else if (visitor.field && visible) {
          visitor.field(el, frame, offsets[frame]);
        }
        if (visitor.field && visible && role && INTERACTIVE.has(role)) visitor.field(el, frame, offsets[frame]);
        for (const child of childrenOf(el)) visit(child, childDepth, frame, childInRef);
        if (visitor.leave) visitor.leave(el);
      };
      for (const child of childrenOf(document.body || document.documentElement)) visit(child, 0, 0, false);
      return { offsets };
    }

    function factsOf(el, role, frame, offset) {
      const name = nameOf(el, role);
      const rect = el.getBoundingClientRect();
      const type = typeOf(el);
      const tokens = el.getAttribute("autocomplete");
      const isButton = tagOf(el) === "button" || ["submit", "button", "reset", "image"].includes(type);
      const submits = submitsForm(el);
      // A submit control sends the form itself; Enter in a field sends it with the form's default button.
      const submitter = submits ? el : defaultSubmitterOf(el.form);
      return {
        tag: tagOf(el), role, name, inputType: type, autocomplete: tokens || null, valueClass: valueClassOf(el, name),
        value: isButton ? cut(el.getAttribute("value") || "", MAX_NAME) || null : null,
        isEditable: isEditable(el), isFileInput: type === "file", isSelect: tagOf(el) === "select", submitsForm: submits,
        formKey: formKeyOf(el, frame), formFields: formFieldsOf(el.form), formActionHost: el.form ? hostOf(actionOf(el.form, submitter), el.ownerDocument.baseURI) : null,
        submitterName: !submits && submitter ? nameOf(submitter, "button") || null : null,
        submitterValue: !submits && submitter ? cut(submitter.getAttribute("value") || "", MAX_NAME) || null : null,
        box: { x: rect.left + offset.x, y: rect.top + offset.y, w: rect.width, h: rect.height },
      };
    }

    function valueOf(el, valueClass) {
      if (op.shared || valueClass) return null;
      const tag = tagOf(el), type = typeOf(el);
      if (tag === "select") return cut(Array.from(el.selectedOptions).map((o) => o.label || o.text).join(", "), MAX_VALUE);
      if (tag === "textarea" || (tag === "input" && TEXT_TYPES.has(type)) || type === "range") return cut(el.value, MAX_VALUE);
      if (isEditable(el)) return cut(textOf(el), MAX_VALUE);
      return null;
    }

    function snapshot() {
      const nodes = [];
      let pending = null;
      let target = op.ref || null, inTarget = !target, targetElement = null, stale = false;
      const flush = () => { if (pending && pending.text.trim()) nodes.push({ depth: pending.depth, role: "text", text: cut(pending.text, MAX_TEXT) }); pending = null; };
      const emit = (node) => { if (inTarget) { flush(); nodes.push(node); } };
      walk({
        ref(el, role, depth, frame, index) {
          const name = nameOf(el, role);
          const fingerprint = fingerprintOf(el, role, name);
          if (target && !inTarget && frame === target.frame && index === target.index) {
            if (fingerprint !== target.fingerprint) { stale = true; this.done = true; return; }
            inTarget = true;
            targetElement = el;
          }
          const valueClass = valueClassOf(el, name);
          const type = typeOf(el);
          const node = { depth, role, name, ref: (frame ? "f" + frame : "") + "e" + index, fingerprint, valueClass, value: valueOf(el, valueClass),
            inputType: type, isEditable: isEditable(el), isFileInput: type === "file", disabled: el.matches(":disabled") || el.getAttribute("aria-disabled") === "true" || null };
          if (role === "checkbox" || role === "radio" || role === "switch") node.checked = !!(el.checked || el.getAttribute("aria-checked") === "true");
          if (role === "link" && el.href) node.href = String(el.href);
          if (submitsForm(el)) { node.submits = true; node.formFields = formFieldsOf(el.form); }
          emit(node);
        },
        landmark(el, role, depth) {
          const node = { depth, role, name: nameOf(el, role) };
          if (role === "heading") node.level = Number((el.getAttribute("aria-level") || tagOf(el).slice(1))) || 2;
          if (role === "img" && !op.full) return;
          emit(node);
        },
        frame(el, depth) { emit({ depth, role: "frame", name: nameOf(el, "frame") }); },
        otherFrame(el, depth) { emit({ depth, role: "frame", name: nameOf(el, "frame"), otherSite: true, frameURL: el.src || null }); },
        text(node, depth) {
          // A label's text is its field's name already.
          if (!op.full || !inTarget || !node.parentElement || node.parentElement.closest("label") || !isVisible(node.parentElement)) return;
          const data = node.data.replace(/\s+/g, " ");
          if (!data.trim()) { if (pending) pending.text += " "; return; }
          if (!pending || pending.depth !== depth || pending.text.length >= MAX_TEXT) { flush(); pending = { depth, text: "" }; }
          pending.text += data;
        },
        leave(el) {
          if (el === targetElement) { flush(); inTarget = false; this.done = true; }
          else if (op.full && pending && styleOf(el).display !== "inline") flush();
        },
      });
      flush();
      if (target && !targetElement) stale = true;
      return { url: location.href, title: document.title, nodes, stale: stale || null };
    }

    /// The element a ref names, if the walk finds one there with the same fingerprint.
    function resolve(target) {
      let found = null, problem = "notFound";
      walk({
        ref(el, role, depth, frame, index, offset) {
          if (frame !== target.frame || index !== target.index) return;
          this.done = true;
          if (target.fingerprint && fingerprintOf(el, role, nameOf(el, role)) !== target.fingerprint) { problem = "stale"; return; }
          found = { el, role, frame, offset };
        },
      });
      return found ? { found } : { problem };
    }

    function offsetOf(el) {
      let x = 0, y = 0, win = windowOf(el);
      while (win && win !== window && win.frameElement) {
        const rect = win.frameElement.getBoundingClientRect();
        x += rect.left + win.frameElement.clientLeft;
        y += rect.top + win.frameElement.clientTop;
        win = win.parent;
      }
      return { x, y };
    }

    function contains(outer, inner) {
      for (let node = inner; node; node = node.parentNode || node.host) if (node === outer) return true;
      return false;
    }

    /// Why no action can reach the element wherever the page is scrolled: it must be connected, visible, and enabled.
    function unusable(el) {
      if (!el.isConnected) return { problem: "detached" };
      if (!isVisible(el)) return { problem: "hidden" };
      if (el.matches(":disabled") || el.getAttribute("aria-disabled") === "true") return { problem: "disabled" };
      return null;
    }

    /// Why an action cannot reach the element, after it scrolls into view, or null when it can: it must be usable and on top at its center.
    function blocked(el) {
      const reason = unusable(el);
      if (reason) return reason;
      scrollIntoView(el);
      const rect = el.getBoundingClientRect();
      const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
      const root = el.getRootNode();
      const hit = (root.elementFromPoint ? root.elementFromPoint(x, y) : null) || el.ownerDocument.elementFromPoint(x, y);
      if (!hit) return { problem: "offscreen" };
      if (contains(el, hit) || contains(hit, el) && hit.localName === "label") return null;
      if (el.labels && Array.from(el.labels).some((label) => contains(label, hit))) return null;
      if (hit.localName === "label" && hit.control === el) return null;
      return { problem: "covered", cover: describe(hit) };
    }

    function element() {
      if (!op.ref) {
        let el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        while (el && (tagOf(el) === "iframe" || tagOf(el) === "frame")) {
          let inner = null;
          try { inner = el.contentDocument; } catch (error) { inner = null; }
          if (!inner || !inner.activeElement) break;
          el = inner.activeElement;
        }
        if (!el || el === document.body || el === document.documentElement) return { url: location.href, viewport: { w: innerWidth, h: innerHeight } };
        return { url: location.href, facts: factsOf(el, roleOf(el) || tagOf(el), 0, offsetOf(el)), viewport: { w: innerWidth, h: innerHeight } };
      }
      const resolved = resolve(op.ref);
      if (!resolved.found) return { url: location.href, problem: resolved.problem };
      const { el, role, frame } = resolved.found;
      const reason = op.scroll ? blocked(el) : unusable(el);
      const facts = factsOf(el, role, frame, offsetOf(el));
      return Object.assign({ url: location.href, facts, viewport: { w: innerWidth, h: innerHeight } }, reason || {});
    }

    function boxes() {
      const list = [];
      const add = (el, offset, kind) => {
        for (const rect of el.getClientRects()) if (rect.width > 0 && rect.height > 0) list.push({ x: rect.left + offset.x, y: rect.top + offset.y, w: rect.width, h: rect.height, kind });
      };
      // Every subtree that shows on the screen, `aria-hidden` and `inert` ones too, as when a dialog's library hides the page behind it from assistive apps.
      walk({
        field(el, frame, offset) {
          const cls = valueClassOf(el, nameOf(el, roleOf(el)));
          if (cls) add(el, offset, cls);
          else if (op.shared && (isEditable(el) || tagOf(el) === "select")) add(el, offset, "shared");
          // The engine's control draws the names of the files the user picked (P7).
          else if (typeOf(el) === "file" && el.files && el.files.length) add(el, offset, "file");
        },
        otherFrame(el, depth, frame, offset) { add(el, offset, "frame"); },
        extensionFrame(el, frame, offset) { add(el, offset, "extension"); },
      }, true);
      const root = document.documentElement;
      return { url: location.href, viewport: { w: innerWidth, h: innerHeight }, page: { w: Math.max(root.scrollWidth, innerWidth), h: Math.max(root.scrollHeight, innerHeight) },
        scrollX, scrollY, boxes: list };
    }

    const MODIFIERS = { Shift: "shiftKey", Control: "ctrlKey", Alt: "altKey", Meta: "metaKey" };
    const KEY_CODES = { Enter: "Enter", Escape: "Escape", Tab: "Tab", Backspace: "Backspace", Delete: "Delete", ArrowUp: "ArrowUp", ArrowDown: "ArrowDown",
      ArrowLeft: "ArrowLeft", ArrowRight: "ArrowRight", Home: "Home", End: "End", PageUp: "PageUp", PageDown: "PageDown", Space: "Space" };

    function pointer(el, kinds, modifiers, detail) {
      const win = windowOf(el);
      const rect = el.getBoundingClientRect();
      const init = Object.assign({ bubbles: true, cancelable: true, composed: true, view: win, clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2,
        button: 0, detail: detail || 1, pointerId: 1, pointerType: "mouse", isPrimary: true }, modifiers);
      for (const kind of kinds) {
        const bubbles = !kind.endsWith("enter");
        const Event = kind.startsWith("pointer") && win.PointerEvent ? win.PointerEvent : win.MouseEvent;
        el.dispatchEvent(new Event(kind, Object.assign({}, init, { bubbles, buttons: kind.endsWith("down") ? 1 : 0 })));
      }
    }

    function press(el, keys) {
      const win = windowOf(el);
      const parts = keys.split("+");
      const name = parts.pop();
      const modifiers = {};
      for (const part of parts) if (MODIFIERS[part]) modifiers[MODIFIERS[part]] = true;
      const key = name === "Space" ? " " : name;
      const code = KEY_CODES[name] || (key.length === 1 ? (/[a-z]/i.test(key) ? "Key" + key.toUpperCase() : /[0-9]/.test(key) ? "Digit" + key : "") : name);
      const init = Object.assign({ key, code, bubbles: true, cancelable: true, composed: true, view: win }, modifiers);
      const proceed = el.dispatchEvent(new win.KeyboardEvent("keydown", init));
      if (proceed && (key.length === 1 || key === "Enter")) el.dispatchEvent(new win.KeyboardEvent("keypress", init));
      el.dispatchEvent(new win.KeyboardEvent("keyup", init));
      // Enter submits with the form's default button, or on a submit input with that input, as a click on it would: the one whose name and `formaction` the policy read. As in a browser, a disabled default button submits nothing.
      if (proceed && key === "Enter" && !Object.keys(modifiers).length && tagOf(el) === "input" && el.form) {
        const button = submitsForm(el) ? el : defaultSubmitterOf(el.form);
        if (!button || !button.matches(":disabled")) el.form.requestSubmit(button || undefined);
      }
    }

    function typeInto(el, text, replace) {
      const win = windowOf(el), doc = el.ownerDocument;
      el.focus();
      if (tagOf(el) === "input" || tagOf(el) === "textarea") {
        const prototype = tagOf(el) === "input" ? win.HTMLInputElement.prototype : win.HTMLTextAreaElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(prototype, "value").set;
        setter.call(el, (replace ? "" : el.value) + text);
        el.dispatchEvent(new win.InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: text }));
        el.dispatchEvent(new win.Event("change", { bubbles: true }));
      } else {
        const selection = doc.getSelection();
        const range = doc.createRange();
        range.selectNodeContents(el);
        if (!replace) range.collapse(false);
        selection.removeAllRanges();
        selection.addRange(range);
        doc.execCommand("insertText", false, text);
      }
    }

    function act() {
      const action = op.action;
      const reply = { url: location.href };
      if (action.kind === "scroll" && !action.ref) {
        const amount = action.amount || Math.round((action.direction === "left" || action.direction === "right" ? innerWidth : innerHeight) * 0.8);
        const dx = action.direction === "left" ? -amount : action.direction === "right" ? amount : 0;
        const dy = action.direction === "up" ? -amount : action.direction === "down" ? amount : 0;
        try { window.scrollBy({ left: dx, top: dy, behavior: "instant" }); } catch (error) { window.scrollBy(dx, dy); }
        return Object.assign(reply, { scrollX, scrollY });
      }
      let el = null;
      if (action.ref) {
        const resolved = resolve(action.ref);
        if (!resolved.found) return Object.assign(reply, { problem: resolved.problem });
        el = resolved.found.el;
        const reason = action.kind === "scroll" ? (el.isConnected ? null : { problem: "detached" }) : blocked(el);
        if (reason) return Object.assign(reply, reason);
      } else {
        el = document.activeElement || document.body;
        while (el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
      }
      reply.hit = describe(el);
      const modifiers = {};
      for (const name of action.modifiers || []) modifiers[MODIFIERS[name]] = true;
      switch (action.kind) {
        case "click": {
          for (let count = 1; count <= (action.count || 1); count += 1) {
            pointer(el, ["pointerover", "pointerenter", "mouseover", "mouseenter", "pointerdown", "mousedown"], modifiers, count);
            if (el.focus) el.focus();
            pointer(el, ["pointerup", "mouseup"], modifiers, count);
            if (Object.keys(modifiers).length || count > 1) pointer(el, ["click"], modifiers, count);
            else el.click();
          }
          if ((action.count || 1) > 1) pointer(el, ["dblclick"], modifiers, 2);
          break;
        }
        case "hover": pointer(el, ["pointerover", "pointerenter", "mouseover", "mouseenter", "pointermove", "mousemove"], {}, 0); break;
        case "type": {
          if (!isEditable(el)) return Object.assign(reply, { problem: "notEditable" });
          typeInto(el, action.text || "", !!action.replace);
          if (action.submit) press(el, "Enter");
          break;
        }
        case "press": press(el, action.keys || ""); break;
        case "select": {
          if (tagOf(el) !== "select") return Object.assign(reply, { problem: "notSelect" });
          const options = Array.from(el.options);
          const chosen = [];
          for (const value of action.values || []) {
            const option = options.find((o) => o.value === value) || options.find((o) => (o.label || o.text).trim() === value.trim());
            if (!option) return Object.assign(reply, { problem: "noOption", missing: value });
            chosen.push(option);
          }
          if (!el.multiple && chosen.length > 1) return Object.assign(reply, { problem: "single" });
          for (const option of options) option.selected = chosen.includes(option);
          const win = windowOf(el);
          el.dispatchEvent(new win.Event("input", { bubbles: true }));
          el.dispatchEvent(new win.Event("change", { bubbles: true }));
          reply.selected = Array.from(el.selectedOptions).map((o) => cut(o.label || o.text, MAX_NAME));
          break;
        }
        case "scroll": {
          scrollIntoView(el);
          reply.scrollX = scrollX;
          reply.scrollY = scrollY;
          break;
        }
      }
      return reply;
    }

    /// The main frame's focused element, through open shadow roots; focus in a frame stays the frame's element.
    function focusedElement() {
      let el = document.activeElement;
      while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
      return el;
    }

    /// The visual viewport in CSS pixels of the layout viewport, which `getBoundingClientRect()` measures in, with its pinch zoom.
    function visual() {
      const vv = window.visualViewport;
      return vv ? { left: vv.offsetLeft, top: vv.offsetTop, scale: vv.scale, w: vv.width, h: vv.height } : { left: 0, top: 0, scale: 1, w: innerWidth, h: innerHeight };
    }

    /// Places the selection where trusted text goes: over the field's text, which the text replaces, or at its end, as `act` adds after it. False for a field without a selection to place, such as an email or number field that holds text.
    function placeSelection(el, replace) {
      const tag = tagOf(el);
      if (tag === "input" || tag === "textarea") {
        let start = null;
        try { start = el.selectionStart; } catch (error) { start = null; }
        if (start === null) return !el.value;
        if (replace) el.select();
        else el.setSelectionRange(el.value.length, el.value.length);
        return true;
      }
      const doc = el.ownerDocument, selection = doc.getSelection(), range = doc.createRange();
      range.selectNodeContents(el);
      if (!replace) range.collapse(false);
      selection.removeAllRanges();
      selection.addRange(range);
      return true;
    }

    /// Readies trusted input (docs/agents.md, Actions): the element passes `act`'s checks; for `type`, and `press` with a ref, it takes focus; for `press` without a ref, the element the policy read still has focus. Then the target check is armed in the same task, so no page script runs between the checks and the arming.
    function prepare() {
      const action = op.action;
      const reply = { url: location.href, viewport: visual() };
      if (action.kind === "scroll" && !action.ref) return reply;
      const check = globalThis.\#(AgentPageScripts.targetCheckName);
      if (!check) return Object.assign(reply, { problem: "noCheck" });
      let el = null, exact = false;
      if (action.ref) {
        const resolved = resolve(action.ref);
        if (!resolved.found) return Object.assign(reply, { problem: resolved.problem });
        if (resolved.found.frame !== 0) return Object.assign(reply, { problem: "inFrame" });
        el = resolved.found.el;
        // A key goes to the focused element whatever lies over it, as after typed text that shows the page's suggestions.
        const reason = action.kind === "press" ? unusable(el) : blocked(el);
        if (reason) return Object.assign(reply, reason);
      } else {
        el = focusedElement();
        if (el && (tagOf(el) === "iframe" || tagOf(el) === "frame")) return Object.assign(reply, { problem: "inFrame" });
        const none = !el || el === document.body || el === document.documentElement;
        if (!action.focus !== none) return Object.assign(reply, { problem: "stale" });
        if (none) {
          el = document.body || document.documentElement;
          exact = true;
        } else {
          const role = roleOf(el) || tagOf(el);
          if (tagOf(el) !== action.focus.tag || role !== action.focus.role || nameOf(el, role) !== action.focus.name) return Object.assign(reply, { problem: "stale" });
        }
      }
      reply.hit = describe(el);
      if (action.kind === "type" || (action.kind === "press" && action.ref)) {
        if (action.kind === "type" && !isEditable(el)) return Object.assign(reply, { problem: "notEditable" });
        // A read-only field takes no text, so trusted text would send no event the check could see.
        if (action.kind === "type" && (tagOf(el) === "input" || tagOf(el) === "textarea") && el.readOnly) return Object.assign(reply, { problem: "readOnly" });
        const before = focusedElement();
        if (!before || !contains(el, before)) el.focus();
        const after = focusedElement();
        // A page whose focus handler moved focus on is stale; an element that takes no focus gets DOM events.
        if (!after || !contains(el, after)) return Object.assign(reply, { problem: after === before ? "noFocus" : "stale" });
        if (action.kind === "type" && !placeSelection(el, !!action.replace)) return Object.assign(reply, { problem: "noSelection" });
      }
      const keyTarget = exact ? null : focusedElement();
      reply.editable = !!keyTarget && isEditable(keyTarget);
      const rect = el.getBoundingClientRect();
      reply.point = { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
      check.arm(el, exact, action.kinds, action.need, action.holdMs);
      return reply;
    }

    function inputState() {
      const check = globalThis.\#(AgentPageScripts.targetCheckName);
      const state = check ? check.read(op.need || null, !!op.cancelRest, !!op.disarm) : { armed: false, seen: 0, cancelled: false, complete: false };
      return Object.assign({ url: location.href, scrollX, scrollY }, state);
    }

    const operations = { snapshot, element, boxes, act, prepare, inputState };
    return JSON.stringify(operations[op.op]());
    """#
}
