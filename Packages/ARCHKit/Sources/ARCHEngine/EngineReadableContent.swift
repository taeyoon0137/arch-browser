// A page's readable text, for features that read pages, such as the page reader. Both adapters run the same script and read its result here; WebKit runs it in its own content world, Chromium in the page's world through the helper's renderer process.
import Foundation

/// The main frame's visible text with its address, title, language, and selected text. It never holds the values of fields or the text of editable areas, so drafts and passwords stay out.
public struct EngineReadableContent: Sendable {
    public var url: URL
    public var title: String
    /// Headings as lines starting with `#`, list items with `- `, and paragraphs separated by blank lines. Link text is kept; link addresses are not.
    public var text: String
    /// The document's `lang` attribute.
    public var language: String?
    /// The text selected outside fields and editable areas, or nil without one. A selection that reaches an editable area is none.
    public var selection: String?
    /// Whether `text` stopped at the limit before the end of the page.
    public var isTruncated: Bool

    public init(url: URL, title: String, text: String, language: String? = nil, selection: String? = nil, isTruncated: Bool = false) {
        self.url = url
        self.title = title
        self.text = text
        self.language = language
        self.selection = selection
        self.isTruncated = isTruncated
    }
}

/// Why a page's readable content could not be read.
public enum EngineReadableContentError: Error {
    /// The page has no document a script can read, as on an engine's own error page, or it went away before answering.
    case unreadable
}

extension EngineReadableContent {
    /// A JavaScript function that takes a character limit and returns the main frame's readable content as JSON text. It walks the visible text and skips scripts, styles, templates, hidden elements, `aria-hidden` subtrees, fields, and editable regions; it follows open shadow roots and their slots. A selection inside a field or an editable region, or one that reaches an editable region, counts as none. Node types and node filter results are compared as numbers because a page can replace the `Node` and `NodeFilter` globals in its own world.
    public static let script = #"""
    (limit) => {
      const skipped = new Set(["script", "style", "template", "noscript", "head", "input", "textarea", "select", "option", "datalist", "iframe", "frame", "object", "embed", "canvas", "svg", "img", "picture", "video", "audio", "map"]);
      const blocks = new Set(["address", "article", "aside", "blockquote", "br", "caption", "dd", "details", "dialog", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "header", "hgroup", "hr", "legend", "main", "nav", "ol", "p", "pre", "section", "summary", "table", "tbody", "tfoot", "thead", "tr", "ul"]);
      // An element without a box of its own, such as a slot or a `display: contents` wrapper, fails the visibility check while its children show.
      const isHidden = (element) => element.getAttribute("aria-hidden") === "true" || element.isContentEditable
        || (typeof element.checkVisibility === "function" && !element.checkVisibility({ visibilityProperty: true, checkVisibilityCSS: true })
          && getComputedStyle(element).display !== "contents");
      let text = "", line = "", linePrefix = "", lastWasItem = false, truncated = false;
      // Ends the current block: list items follow each other on single lines, other blocks after a blank line.
      const emit = () => {
        const content = line.replace(/\s+/g, " ").trim();
        const prefix = linePrefix;
        line = "";
        linePrefix = "";
        if (!content || truncated) return;
        const isItem = prefix === "- ";
        const separator = text ? (isItem && lastWasItem ? "\n" : "\n\n") : "";
        let block = prefix + content;
        const room = limit - text.length - separator.length;
        if (block.length > room) {
          truncated = true;
          // A cut must not end inside a surrogate pair, which JSON cannot carry on its own.
          block = block.slice(0, Math.max(room, 0)).replace(/[\uD800-\uDBFF]$/, "");
          if (!block) return;
        }
        text += separator + block;
        lastWasItem = isItem;
      };
      const visit = (nodes, prefix) => {
        for (const node of nodes) {
          if (truncated) return;
          if (node.nodeType === 3) {
            if (!line) linePrefix = prefix;
            line += node.data;
            continue;
          }
          if (node.nodeType !== 1) continue;
          const tag = node.localName;
          if (skipped.has(tag) || isHidden(node)) continue;
          const heading = /^h([1-6])$/.exec(tag);
          // Text right inside a closed `details` has no element of its own to fail the visibility check, so only its summary is read.
          const children = node.shadowRoot ? node.shadowRoot.childNodes
            : tag === "slot" ? node.assignedNodes({ flatten: true })
            : tag === "details" && !node.open ? [...node.children].filter((child) => child.localName === "summary")
            : node.childNodes;
          if (heading || tag === "li" || blocks.has(tag)) {
            emit();
            visit(children, heading ? "#".repeat(Number(heading[1])) + " " : tag === "li" ? "- " : prefix);
            emit();
          } else {
            if ((tag === "td" || tag === "th") && node.cellIndex > 0) line += " | ";
            visit(children, prefix);
          }
        }
      };
      const isEditable = (node) => {
        const element = node && (node.nodeType === 1 ? node : node.parentElement);
        return !!element && (element.isContentEditable || !!element.closest("input, textarea, select"));
      };
      // Whether an element under `root` that `range` reaches is editable, or holds an editable element in its open shadow tree. A shadow tree's nodes lie outside the range's tree, so a host the range reaches counts with its whole shadow tree, which is walked with no range. 1 shows elements only; 1 and 2 accept a node and reject its subtree.
      const reachesEditable = (root, range) => {
        const walker = document.createTreeWalker(root, 1, { acceptNode: (node) => (!range || range.intersectsNode(node)) ? 1 : 2 });
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (node.isContentEditable || (node.shadowRoot && reachesEditable(node.shadowRoot, null))) return true;
        }
        return false;
      };
      const selection = (() => {
        const selected = getSelection();
        if (!selected || selected.isCollapsed || !selected.rangeCount) return null;
        const range = selected.getRangeAt(0);
        const ancestor = range.commonAncestorContainer;
        if (isEditable(document.activeElement) || isEditable(ancestor)) return null;
        // A selection across an editable area, as Select All makes, would carry its draft, so it counts as none.
        const container = ancestor.nodeType === 1 ? ancestor : ancestor.parentElement;
        if (container && reachesEditable(container, range)) return null;
        return String(selected).replace(/[^\S\n]+/g, " ").replace(/\s*\n\s*/g, "\n").trim() || null;
      })();
      const root = document.body || document.documentElement;
      if (limit > 0 && root) {
        visit([root], "");
        emit();
      }
      return JSON.stringify({ url: location.href, title: document.title, text, language: document.documentElement?.lang || null, selection, truncated });
    }
    """#

    /// Reads the JSON text that `script` returns. Throws `unreadable` for anything else, such as nil from a page the script could not run in.
    public init(scriptResult: String?) throws {
        /// The JSON object that `script` returns.
        struct Payload: Decodable {
            var url: String
            var title: String
            var text: String
            var language: String?
            var selection: String?
            var truncated: Bool
        }
        guard let data = scriptResult?.data(using: .utf8), let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let url = URL(engineString: payload.url) else { throw EngineReadableContentError.unreadable }
        self.init(url: url, title: payload.title, text: payload.text, language: payload.language, selection: payload.selection, isTruncated: payload.truncated)
    }
}
