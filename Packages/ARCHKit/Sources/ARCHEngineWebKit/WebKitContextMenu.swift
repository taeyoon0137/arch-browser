// Shows the app's context menu on the WebKit engine. WebKit builds its own menu for each click; the adapter keeps only the editing and spelling items WebKit runs itself, marks them for the UI delegate, and learns the clicked link, image, and selection from a script in its own content world.
import AppKit
import ARCHEngine
import WebKit

/// Reports the element under a context click. It runs in its own content world, so pages cannot read or replace it.
final class WebKitContextMenuScript: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "ARCHContextMenu")
    static let handlerName = "archContextMenu"
    static let source = """
    window.addEventListener('contextmenu', (event) => {
      if (!event.isTrusted) return;
      let link = null, image = null, media = null;
      const absolute = (value, node) => { try { return new URL(value, node.baseURI).href; } catch { return null; } };
      for (const node of event.composedPath()) {
        if (!(node instanceof Element)) continue;
        if (!link && (node.localName === 'a' || node.localName === 'area')) {
          const href = typeof node.href === 'object' ? node.href.baseVal : node.href;
          if (href) link = absolute(href, node);
        }
        if (!image && node instanceof HTMLImageElement) image = node.currentSrc || node.src || null;
        if (!image && node instanceof SVGImageElement && node.href.baseVal) image = absolute(node.href.baseVal, node);
        if (!image && node instanceof HTMLInputElement && node.type === 'image' && node.src) image = node.src;
        if (!image && node instanceof HTMLObjectElement && node.data && node.type.startsWith('image/')) image = node.data;
        if (!image && node instanceof HTMLAreaElement) {
          // An image map's area is not inside its image, so the image is found through the map's name.
          const map = node.closest('map');
          const name = map && (map.name || map.id);
          const owner = name && node.getRootNode().querySelector(`img[usemap="#${CSS.escape(name)}"]`);
          if (owner) image = owner.currentSrc || owner.src || null;
        }
        if (!media && node instanceof HTMLMediaElement) media = node.currentSrc || null;
      }
      window.webkit.messageHandlers.\(handlerName).postMessage({ link, image, media, selection: String(window.getSelection() ?? '') });
    }, true);
    """

    /// Adds the script and its handler once per content controller; popups share their opener's.
    static func install(in controller: WKUserContentController) {
        guard !controller.userScripts.contains(where: { $0.source == source }) else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.add(WebKitContextMenuScript(), contentWorld: world, name: handlerName)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let webView = message.webView as? WebKitWebView else { return }
        func url(_ key: String) -> URL? { (body[key] as? String).flatMap(URL.init(engineString:)) }
        let selection = body["selection"] as? String
        webView.pendingElement = EngineContextMenuElement(linkURL: url("link"), imageURL: url("image"), mediaURL: url("media"),
                                                          selectedText: selection?.isEmpty == false ? selection : nil, isInMainFrame: message.frameInfo.isMainFrame)
    }
}

extension WebKitWebContents {
    func installContextMenu() {
        WebKitContextMenuScript.install(in: webView.configuration.userContentController)
    }

    /// Keeps WebKit's editing and spelling items, which WebKit runs itself, and lets the UI delegate build the rest. The menu is changed in place, because WebKit tracks the one it passed in.
    func prepareContextMenu(_ menu: NSMenu, for element: EngineContextMenuElement) {
        guard let uiDelegate, let kept = Self.keptContextMenuItems(of: menu, for: element) else { return }
        // No Services items, which the Chromium engine's menu cannot show.
        menu.allowsContextMenuPlugIns = false
        menu.removeAllItems()
        for item in kept {
            item.identifier = Self.contextMenuRoles[item.tag]
            item.image = nil
            menu.addItem(item)
        }
        var element = element
        // WebKit offers Paste only in editable content.
        if kept.contains(where: { $0.tag == 14 }) {
            element.isEditable = true
            let item = NSMenuItem(title: "Select All", action: #selector(WebKitWebView.selectAllFromContextMenu(_:)), keyEquivalent: "")
            item.target = webView
            item.identifier = EngineContextMenuItem.selectAll
            item.isEnabled = true
            menu.addItem(item)
        }
        uiDelegate.webContents(self, willShowContextMenuFor: element, menu: menu)
    }

    /// The roles of the items WebKit runs itself, by tag. WebKit's tags are WebCore's menu actions; on macOS they equal the deprecated WebMenuItemTag values in the SDK's WebUIDelegate.h.
    static let contextMenuRoles: [Int: NSUserInterfaceItemIdentifier] = [
        8: EngineContextMenuItem.copy, 13: EngineContextMenuItem.cut, 14: EngineContextMenuItem.paste,
        15: EngineContextMenuItem.spellingSuggestion, 16: EngineContextMenuItem.noSpellingSuggestions,
    ]

    /// The items of WebKit's menu that the app's menu keeps: WebKit's own items with a role, in WebKit's order. Nil when WebKit's menu stays as it is: a menu without WebKit's own items, one with items a page element provides, and one whose element the script could not see.
    static func keptContextMenuItems(of menu: NSMenu, for element: EngineContextMenuElement) -> [NSMenuItem]? {
        // Compared only, never called.
        let forward = Selector(("forwardContextMenuAction:"))
        // A menu a page element provides, such as the playback speed and subtitles menu of video controls, uses WebCore's custom tags.
        func hasProvidedItems(_ menu: NSMenu) -> Bool {
            menu.items.contains { ($0.action == forward && (5000...5999).contains($0.tag)) || ($0.submenu.map(hasProvidedItems) ?? false) }
        }
        guard menu.items.contains(where: { $0.action == forward }), !hasProvidedItems(menu) else { return nil }
        // WebKit's Copy Link (3) and Copy Image (6) items show what its own hit test found. When the script could not see the element, as inside a closed shadow root, WebKit's menu stays rather than a menu that misses it.
        let tags = Set(menu.items.map(\.tag))
        if (tags.contains(3) && element.linkURL == nil) || (tags.contains(6) && element.imageURL == nil) { return nil }
        return menu.items.filter { $0.action == forward && contextMenuRoles[$0.tag] != nil }
    }
}
