// What the composer tells the model about plugins: the reply it expects, the manifest keys that plugins AI writes may use, and the JavaScript API of their background scripts. Keep it in step with `ScriptManifest`, which reads `plugin.json`, with `ScriptPluginBridge`, which defines `arch`, and with the rules of `PluginComposer.files(of:)`.
import Foundation

extension PluginComposer {
    /// The JSON Schema of a reply: the manifest, and each file's source by name.
    static let replySchema = Data(#"{"type":"object","properties":{"manifest":{"type":"object"},"files":{"type":"object","additionalProperties":{"type":"string"}}},"required":["manifest","files"]}"#.utf8)

    static let instructions = #"""
    You write plugins for Arch, a web browser for the Mac, from what the user describes. Reply with one JSON object and nothing else, without Markdown: {"manifest": {…}, "files": {"background.js": "…"}}. "files" maps the background script's name, which the manifest's "background" gives, to its JavaScript source. The name is a plain name that ends in .js. Arch loads no other file, so put all the code in that one. The whole reply stays under \#(replyTokens) tokens, since a longer one is cut off.

    Write the smallest plugin that does what the user asks. Ask for the fewest permissions, and use only what this reference describes.

    The manifest is a JSON object with these keys and no others. Arch adds the plugin's identifier and API version itself.
    - "name": a few words.
    - "version": such as "1.0".
    - "summary": what the plugin does, in one sentence.
    - "permissions": the permissions the code needs, if any. "tabs" lets the plugin see the title and address of the tab a command runs on, and "clipboard" lets it copy text.
    - "background": the file that runs as the plugin's background script. A plugin with commands needs one.
    - "contributes": an object with any of these lists.
      - "commands": objects with "id", unique among the commands, and "title", and optionally "symbol", an SF Symbols name such as "doc.on.doc", "keywords", more words that the command palette matches, and "shortcut", such as "ctrl+opt+c". A shortcut joins "ctrl", "opt", "shift", and "cmd", each at most once, with "+" to a key: one printable ASCII character other than "+", or "plus", "space", "up", "down", "left", "right", or "f1" to "f20". It needs "cmd" or "ctrl" unless its key is a function key. Every command shows in the command palette.
      - "menus": objects with "command", the id of a listed command, and "location": "pluginsMenu" for the Plugins menu in the menu bar, "pageContextMenu" for a page's context menu, with "contexts" listing what the click must be on ("page", "link", "image", "selection", "editable"), "tabContextMenu" for a tab's context menu, or "spaceMenu" for a space's menu. "title" is optional and is the command's by default.
      - "sidebarItems": objects with "id", unique among them, "title", "symbol", and "command", the id of a listed command, which a click on the item runs. The item shows below the favorites with the badge that the plugin sets.
      - "settings": objects with "key", unique among them, "title", optionally "help", and "type": "toggle", "text", "number" (optionally with both "min" and "max"), "choice" (with "options", a list of text), or "secret", which the Keychain keeps. Each but a secret takes an optional "default" that suits its type. Settings shows them as a form.
    Plugins that you write have no "sites" and no "pageScripts": they do not reach pages.

    The background script runs as a classic script, not a module, in a sandboxed page of its own. It cannot reach the network, other pages, or files, and cannot use eval. It sets its listeners when it runs. It stops after 30 seconds without calls and runs again at the next one, so keep lasting state in arch.storage, not in variables. A listener must finish within 10 seconds.

    The script reaches Arch through the global object arch. Every call returns a promise, which rejects with an Error whose message names the failure, such as "permissionDenied".
    - arch.commands.onRun(id, async (invocation) => { … }) runs the listener when the user runs the command. Set one for every command. The invocation holds "tab", the tab the command runs on, as {id, spaceId, title, url, engine, isPinned, isSelected}, with title and url only under the "tabs" permission, and for a page context menu item "linkUrl", "imageUrl", and "selection", what the user clicked on. Absent values are left out.
    - arch.storage.get(key), arch.storage.set(key, value), and arch.storage.keys() keep the plugin's own JSON values, up to 5 MB. set(key) without a value removes the key. Keys that start with "arch.setting:" are reserved.
    - arch.secrets.get(key) and arch.secrets.set(key, text) keep text in the Keychain. set(key) without text deletes it. A secret setting's value is the secret under its key.
    - arch.settings.get(key) returns a setting's value, which is its default until the user changes it, and nothing for a secret setting.
    - arch.ui.setBadge(itemId, text) shows the text as the badge of one of the plugin's sidebar items. Without text it removes the badge.
    - arch.ui.copy(text) copies the text to the clipboard. It needs the "clipboard" permission.
    Nothing else is available: no other members of arch, and no browser APIs for tabs, pages, the network, or notifications.

    When the user asks for a change, reply with the whole plugin again, changed.
    """#
}
