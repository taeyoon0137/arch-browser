// When a tab's icon outlives a change of its page's address: within one host, including the same-document navigations a single-page app makes, and never onto another host or a page without one. Icons load without any profile's cookies or stored credentials, only from web and data URLs, and only up to a size and a time limit; other images that a page names load the same way up to a limit of their own.
import AppKit
@testable import ARCHEngine
import Foundation
import Testing

@Suite struct FaviconLoaderTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func pagesOfOneHostKeepTheIcon() {
        // `history.pushState`, a fragment, another document, and the secure scheme stay on the host.
        #expect(FaviconLoader.keepsIcon(from: url("https://example.com/"), to: url("https://example.com/repo/issues")))
        #expect(FaviconLoader.keepsIcon(from: url("https://example.com/page"), to: url("https://example.com/page#section")))
        #expect(FaviconLoader.keepsIcon(from: url("http://example.com/"), to: url("https://example.com/sign-in?next=%2F")))
        #expect(FaviconLoader.keepsIcon(from: url("https://Example.com/"), to: url("https://example.com/")))
    }

    @Test func anotherHostOrAPageWithoutOneDropsTheIcon() {
        #expect(!FaviconLoader.keepsIcon(from: url("https://example.com/"), to: url("https://example.org/")))
        #expect(!FaviconLoader.keepsIcon(from: url("https://example.com/"), to: url("https://www.example.com/")))
        #expect(!FaviconLoader.keepsIcon(from: url("https://example.com/"), to: url("about:blank")))
        #expect(!FaviconLoader.keepsIcon(from: url("file:///tmp/a.html"), to: url("file:///tmp/b.html")))
        #expect(!FaviconLoader.keepsIcon(from: nil, to: url("https://example.com/")))
        #expect(!FaviconLoader.keepsIcon(from: url("https://example.com/"), to: nil))
    }

    @Test func iconsLoadWithoutCookiesOrCredentialsWithinThirtySeconds() {
        let configuration = FaviconLoader.session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.timeoutIntervalForResource == 30)
    }

    @MainActor @Test func iconsOfOtherSchemesLoadNothing() {
        for string in ["file:///etc/hosts", "FILE:///dev/zero", "ftp://example.com/favicon.ico", "about:blank"] {
            var answers: [NSImage?] = []
            FaviconLoader.load(url(string)) { answers.append($0) }
            #expect(answers == [nil], "\(string)")
        }
    }

    @Test func aBodyPastTheLimitLoadsNothing() async {
        let limit = FaviconLoader.maximumSize
        let body = { (count: Int) in self.url("data:application/octet-stream;base64," + Data(repeating: 7, count: count).base64EncodedString()) }
        #expect(await FaviconLoader.download(body(limit))?.count == limit)
        #expect(await FaviconLoader.download(body(limit + 1)) == nil)
        // An endless body without a stated length stops at the limit.
        #expect(await FaviconLoader.download(URL(fileURLWithPath: "/dev/zero")) == nil)
        // Another image, such as Now Playing's artwork, sets a limit of its own.
        #expect(await FaviconLoader.download(body(limit + 1), limit: limit + 1)?.count == limit + 1)
        #expect(await FaviconLoader.download(body(11), limit: 10) == nil)
        #expect(await FaviconLoader.download(URL(fileURLWithPath: "/dev/zero"), limit: 4 * limit) == nil)
    }

    @Test func declarationsPreferVectorsThenSuitableBitmapsAndRemoveDuplicates() {
        let declarations = FaviconDeclarations(html: """
        <link rel="icon" type="image/png" sizes="192x192" href="large.png">
        <link rel="icon" sizes="16x16" href="small.png">
        <link rel="icon" sizes="32x32" href="retina.png">
        <link rel="ICON" sizes="any" href="favicon.ico">
        <link rel="shortcut icon" type="image/svg+xml" href="vector">
        <link rel="icon" sizes="32x32" href="retina.png">
        """, pageURL: url("https://example.com/pages/home"))
        #expect(declarations.icons.map(\.lastPathComponent) == ["vector", "favicon.ico", "retina.png", "large.png", "small.png"])
    }

    @Test func linksResolveAgainstTheFinalPageAndItsBaseWithHTMLAttributesDecoded() {
        let declarations = FaviconDeclarations(html: """
        <!-- <link rel=icon href=ignored.png> -->
        <script>const sample = '<link rel=icon href=ignored-too.png>';</script>
        <LINK HREF='image.png?one=1&amp;two=&#50;' REL='shortcut ICON' SIZES='32x32'>
        <base href='../assets/'>
        <base href='https://ignored.example/'>
        <link rel=manifest href=app.webmanifest>
        <link href="touch.png" rel="apple-touch-icon-precomposed">
        <link rel="not-an-icon" href="unrelated.png">
        <link rel=icon href=file:///tmp/private.png>
        """, pageURL: url("https://redirected.example/path/home"))
        #expect(declarations.icons == [url("https://redirected.example/assets/image.png?one=1&two=2")])
        #expect(declarations.manifests == [url("https://redirected.example/assets/app.webmanifest")])
        #expect(declarations.touchIcons == [url("https://redirected.example/assets/touch.png")])
        let escaped = FaviconDeclarations(html: "<link rel=icon href='icon.svg?x=&amp;amp;&amp;y=1'>", pageURL: url("https://example.com/"))
        #expect(escaped.icons == [url("https://example.com/icon.svg?x=&amp;&y=1")])
    }

    @Test func relativeLinksWithoutABaseUseTheRedirectedPageDirectory() {
        let declarations = FaviconDeclarations(html: "<link rel=icon href=icons/site.png>", pageURL: url("https://final.example/new/index"))
        #expect(declarations.icons == [url("https://final.example/new/icons/site.png")])
        #expect(FaviconLoader.defaultIconURL(for: url("https://user:pass@final.example/new/index?q=1#top")) == url("https://final.example/favicon.ico"))
        #expect(FaviconLoader.defaultIconURL(for: url("http-other://example.com/")) == nil)
    }

    @Test func manifestsUseTheirFinalURLAndSuitableUnmaskedIcons() {
        let data = Data(#"{"icons":[{"src":"../large.png","sizes":"512x512","type":"image/png"},{"src":"retina.png","sizes":"32x32"},{"src":"mask.png","sizes":"32x32","purpose":"maskable"},{"src":"mono.png","purpose":"monochrome"},{"src":"vector.svg","sizes":"any","purpose":"any maskable"},{"src":"file:///tmp/private.png"},{"src":"retina.png","sizes":"32x32"}]}"#.utf8)
        #expect(FaviconDeclarations.manifestIcons(in: data, manifestURL: url("https://cdn.example/app/site.webmanifest")) == [
            url("https://cdn.example/app/vector.svg"), url("https://cdn.example/app/retina.png"), url("https://cdn.example/large.png")
        ])
        #expect(FaviconDeclarations.manifestIcons(in: Data("not json".utf8), manifestURL: url("https://example.com/manifest")) == [])
    }

    @Test func declarationsKeepTouchIconsSeparateAndLimitRequests() {
        let links = (1...30).map { "<link rel=icon href='icon\($0).png'>" }.joined()
        let declarations = FaviconDeclarations(html: links + """
        <link rel="apple-touch-icon" href="touch.png">
        <link rel="manifest" href="one.json"><link rel="manifest" href="two.json"><link rel="manifest" href="three.json">
        """, pageURL: url("https://example.com/"))
        #expect(declarations.icons.count == 16)
        #expect(declarations.touchIcons == [url("https://example.com/touch.png")])
        #expect(declarations.manifests.count == 2)
    }

    private var svg: Data {
        Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32"><path fill="red" d="M0 0h32v32H0z"/></svg>"#.utf8)
    }

    private func dataURL(_ data: Data, type: String) -> URL {
        url("data:" + type + ";base64," + data.base64EncodedString())
    }

    @Test func nativeDecoderAcceptsSVGAndRejectsHTMLAtAnIconAddress() {
        #expect(FaviconLoader.decode(svg)?.size == NSSize(width: 32, height: 32))
        #expect(FaviconLoader.decode(Data("<html><body>Not an icon</body></html>".utf8)) == nil)
    }

    @MainActor @Test func anUndecodableCandidateDoesNotHideTheNextIcon() async {
        let image = await withCheckedContinuation { continuation in
            FaviconLoader.loadFirst([dataURL(Data("bad icon".utf8), type: "text/html"), dataURL(svg, type: "image/svg+xml")]) {
                continuation.resume(returning: $0)
            }
        }
        #expect(image?.isValid == true)
    }

    @MainActor @Test func failedDeclaredIconsFallBackToManifestIcons() async {
        let icon = dataURL(svg, type: "image/svg+xml")
        let manifest = dataURL(Data("{\"icons\":[{\"src\":\"\(icon.absoluteString)\",\"sizes\":\"any\",\"type\":\"image/svg+xml\"}]}".utf8), type: "application/manifest+json")
        let html = "<link rel=icon href='data:text/plain,invalid'><link rel=manifest href='\(manifest.absoluteString)'>"
        let image = await withCheckedContinuation { continuation in
            FaviconLoader.loadPageIcon(for: url("https://manifest.example/"), headHTML: html) { continuation.resume(returning: $0) }
        }
        #expect(image?.isValid == true)
    }

    @MainActor @Test func failedManifestFallsBackToTouchIcon() async {
        let html = "<link rel=manifest href='data:application/json,invalid'><link rel=apple-touch-icon href='\(dataURL(svg, type: "image/svg+xml").absoluteString)'>"
        let image = await withCheckedContinuation { continuation in
            FaviconLoader.loadPageIcon(for: url("https://touch.example/"), headHTML: html) { continuation.resume(returning: $0) }
        }
        #expect(image?.isValid == true)
    }

    @MainActor @Test func nonWebPagesCanDeclareDataIconsWithoutFetchingTheirPage() async {
        let iconURL = dataURL(svg, type: "image/svg+xml")
        let headImage = await withCheckedContinuation { continuation in
            FaviconLoader.loadPageIcon(for: url("about:blank"), headHTML: "<link rel=icon href='\(iconURL.absoluteString)'>") {
                continuation.resume(returning: $0)
            }
        }
        #expect(headImage?.isValid == true)
        let reportedImage = await withCheckedContinuation { continuation in
            FaviconLoader.loadPageIcon(for: url("file:///tmp/private.html"), iconURLs: [iconURL]) { continuation.resume(returning: $0) }
        }
        #expect(reportedImage?.isValid == true)
        var didComplete = false
        FaviconLoader.loadPageIcon(for: url("file:///tmp/private.html")) { image in
            #expect(image == nil)
            didComplete = true
        }
        #expect(didComplete)
    }

    @Test func pageAndIconRequestsStripEmbeddedCredentials() {
        #expect(FaviconLoader.withoutCredentials(url("https://name:password@example.com/icon.svg?q=1")) == url("https://example.com/icon.svg?q=1"))
        #expect(FaviconLoader.withoutCredentials(url("data:text/plain,icon")) == url("data:text/plain,icon"))
    }

    @Test func redirectedLargePagesKeepABoundedPrefixAndResolveTheirIcons() async throws {
        let configuration = FaviconLoader.session.configuration
        configuration.protocolClasses = [FaviconStubURLProtocol.self]
        let session = URLSession(configuration: configuration, delegate: FaviconLoader.session.delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let response = try #require(await FaviconLoader.downloadResponse(url("https://name:password@source.favicon-test.invalid/redirect"), limit: FaviconLoader.maximumSize, allowPrefix: true, using: session))
        let finalURL = try #require(response.1.url)
        #expect(finalURL == url("https://final.favicon-test.invalid/new/page"))
        #expect(response.0.count == FaviconLoader.maximumSize)
        let declarations = FaviconDeclarations(html: String(decoding: response.0, as: UTF8.self), pageURL: finalURL)
        #expect(declarations.icons == [url("https://final.favicon-test.invalid/new/icon.svg")])
        #expect(await FaviconLoader.downloadResponse(finalURL, limit: FaviconLoader.maximumSize, using: session) == nil)
    }

    @Test func aRedirectedPageWithoutDeclarationsFallsBackAtItsFinalOrigin() async throws {
        let configuration = FaviconLoader.session.configuration
        configuration.protocolClasses = [FaviconStubURLProtocol.self]
        let session = URLSession(configuration: configuration, delegate: FaviconLoader.session.delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for path in ["redirect-empty", "redirect-missing"] {
            let response = try #require(await FaviconLoader.downloadResponse(url("https://source.favicon-test.invalid/" + path), limit: FaviconLoader.maximumSize, allowPrefix: true, using: session))
            let finalURL = try #require(response.1.url)
            #expect(FaviconDeclarations(html: String(decoding: response.0, as: UTF8.self), pageURL: finalURL).icons.isEmpty)
            #expect(FaviconLoader.defaultIconURL(for: finalURL) == url("https://final.favicon-test.invalid/favicon.ico"))
            let iconURL = try #require(FaviconLoader.defaultIconURL(for: finalURL))
            let icon = try #require(await FaviconLoader.downloadResponse(iconURL, limit: FaviconLoader.maximumSize, using: session))
            #expect(FaviconLoader.decode(icon.0)?.isValid == true)
        }
    }
}

/// An isolated transport for redirects and bounded responses; it never opens a socket.
private final class FaviconStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix("favicon-test.invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path.hasPrefix("/redirect") {
            let path = url.path == "/redirect" ? "page" : url.path == "/redirect-missing" ? "missing" : "empty"
            let destination = URL(string: "https://name:password@final.favicon-test.invalid/new/" + path)!
            var redirected = URLRequest(url: destination)
            redirected.setValue("private", forHTTPHeaderField: "Authorization")
            redirected.setValue("private", forHTTPHeaderField: "Cookie")
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": destination.absoluteString])!)
            return
        }
        let clean = url.user == nil && url.password == nil && request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil
        let body: Data
        let type: String
        if url.path == "/new/page" {
            body = Data(("<link rel=icon href=icon.svg>" + String(repeating: " ", count: FaviconLoader.maximumSize)).utf8)
            type = "text/html"
        } else if url.path == "/favicon.ico" {
            body = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><path fill="red" d="M0 0h16v16H0z"/></svg>"#.utf8)
            type = "image/svg+xml"
        } else {
            body = Data("<html><head></head></html>".utf8)
            type = "text/html"
        }
        let response = HTTPURLResponse(url: url, statusCode: clean ? (url.path == "/new/missing" ? 404 : 200) : 401, httpVersion: nil, headerFields: ["Content-Type": type, "Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
