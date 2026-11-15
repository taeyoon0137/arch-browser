// Run by scripts/check_page_reads.py inside its temporary app bundle, with CEF's normal helper apps.
import AppKit
import ARCHEngine
import ARCHEngineChromium
import CEFBridge
import Foundation

final class PageReadCheck: NSObject, NSApplicationDelegate, EngineWebContentsUIDelegate {
    let root = Bundle.main.bundleURL.deletingLastPathComponent()
    var fixture: URL { root.appendingPathComponent("fixture.html") }
    var browser: (any EngineBrowser)?
    var window: NSWindow?
    private var finished = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A direct launch has no test profile or mock keychain. Only start CEF under the prepared fixture bundle.
        guard Bundle.main.bundleIdentifier == "xyz.taeyoon.arch.engine-read-check",
              CommandLine.arguments.contains("--use-mock-keychain"),
              FileManager.default.fileExists(atPath: fixture.path) else {
            finish("Launch this check with scripts/check_page_reads.py.")
            return
        }
        let frameworks = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks")
        let framework = frameworks.appendingPathComponent("Chromium Embedded Framework.framework")
        let helper = frameworks.appendingPathComponent("Arch Helper.app/Contents/MacOS/Arch Helper")
        guard let engine = ChromiumEngine(frameworkPath: framework.path, helperPath: helper.path) else {
            finish("The fixture bundle has no Chromium framework.")
            return
        }
        do {
            let profile = root.appendingPathComponent("profile", isDirectory: true)
            let app = try engine.makeApplication(configuration: EngineApplicationConfiguration(userDataDirectory: profile, cacheDirectory: profile))
            // The global context belongs to the freshly created profile for this process.
            app.createBrowserContext(storageIdentifier: nil) { result in
                do {
                    let browser = app.createBrowser(context: try result.get())
                    self.browser = browser
                    let page = browser.createWebContents(EngineWebContentsConfiguration())
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: .borderless, backing: .buffered, defer: false)
                    self.window = window
                    window.contentView = page.view
                    page.uiDelegate = self
                    page.navigationController.load(URLRequest(url: self.fixture))
                } catch {
                    self.finish("Could not create the Chromium context: \(error)")
                }
            }
        } catch {
            finish("Could not start Chromium: \(error)")
        }
    }

    func webContentsDidFinishLoadingDocument(_ page: any EngineWebContents) {
        guard page.url?.standardizedFileURL == fixture.standardizedFileURL else { return }
        page.readableContent(limit: 2000) { result in
            do {
                let content = try result.get()
                guard content.url.standardizedFileURL == self.fixture.standardizedFileURL,
                      content.title == "Arch page read", content.text == "Intro text\n\nMiddle text\n\nOutro text",
                      !content.isTruncated else {
                    self.finish("The extracted page address, title, text, or truncation flag differed from the fixture.")
                    return
                }
                self.finish(nil)
            } catch {
                self.finish("Chromium could not extract the fixture: \(error)")
            }
        }
    }

    private func finish(_ error: String?) {
        guard !finished else { return }
        finished = true
        // Return to the run loop before closing a page that just called its delegate.
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
            self.window?.contentView = nil
            self.browser?.closeAllWebContents()
            if let error {
                FileHandle.standardError.write(Data((error + "\n").utf8))
                ARCHCEFRuntime.shutdown()
                exit(1)
            }
            print("Chromium read the visible paragraphs and omitted the form fields and editable drafts.")
            NSApp.terminate(nil)
        }
    }
}

let application = ARCHCEFApplication.shared
let check = PageReadCheck()
application.setActivationPolicy(.prohibited)
application.delegate = check
application.run()
