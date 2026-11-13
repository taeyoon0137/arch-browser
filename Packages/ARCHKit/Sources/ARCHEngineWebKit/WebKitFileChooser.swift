// A page's file chooser on WebKit. `WKOpenPanelParameters` tells publicly only whether the input takes several files or a folder; the types the page accepts come from its private `_acceptedMIMETypes` and `_acceptedFileExtensions`, behind the private API flags. With a flag off or a member missing, the request names no types and the panel offers every file, as for an input without `accept`.
import ARCHEngine
import ARCHPrivateAPI
import Foundation
import WebKit

/// The private members that read an open panel's accepted types, registered on the flags page and checked before use.
enum WebKitFileChooserAPI {
    static let acceptedTypesAPIID = "webkit.openPanelAcceptedTypes"
    static let featureID = "webkit.fileChooserTypes"
    private static let mimeTypesKey = "_acceptedMIMETypes"
    private static let extensionsKey = "_acceptedFileExtensions"

    @MainActor static func register() {
        let flags = PrivateAPIFlags.shared
        flags.register(PrivateAPI(id: acceptedTypesAPIID, name: "WKOpenPanelParameters._acceptedMIMETypes and _acceptedFileExtensions", framework: "WebKit") {
            [mimeTypesKey, extensionsKey].allSatisfy { WKOpenPanelParameters.instancesRespond(to: NSSelectorFromString($0)) }
        })
        flags.register(PrivateAPIFeature(id: featureID, name: "File types in WebKit pages' file choosers", apiIDs: [acceptedTypesAPIID]))
    }

    /// Whether the feature may run now. WebKit asks on the main thread, where the flags live.
    static var isAllowed: Bool { MainActor.assumeIsolated { PrivateAPIFlags.shared.allows(featureID) } }

    /// The request for an open panel: a folder for an input with `webkitdirectory`, several files for one with `multiple`, otherwise one file, with the page's accepted types while the flags allow reading them. WebKit gives the types in lowercase, MIME types first.
    static func request(for parameters: WKOpenPanelParameters) -> EngineFileChooserRequest {
        let mode: EngineFileChooserRequest.Mode = parameters.allowsDirectories ? .openFolder : parameters.allowsMultipleSelection ? .openFiles : .openFile
        return EngineFileChooserRequest(mode: mode, acceptedTypes: isAllowed ? acceptedTypes(of: parameters) : [])
    }

    /// Key-value coding reads the getters the availability check looked for.
    static func acceptedTypes(of parameters: WKOpenPanelParameters) -> [String] {
        [mimeTypesKey, extensionsKey].flatMap { parameters.value(forKey: $0) as? [String] ?? [] }
    }
}

/// Answers WebKit's open panel once: with the UI delegate's answer, or with nil when the delegate lets its completion go unanswered, because WebKit raises an exception when it releases an open panel's completion handler that was never called.
final class WebKitFileChooserAnswer {
    private var handler: (([URL]?) -> Void)?

    init(_ handler: @escaping ([URL]?) -> Void) {
        self.handler = handler
    }

    func send(_ urls: [URL]?) {
        let handler = handler
        self.handler = nil
        handler?(urls)
    }

    deinit {
        handler?(nil)
    }
}
