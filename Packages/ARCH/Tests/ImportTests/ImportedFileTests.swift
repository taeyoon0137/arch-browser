// The file import: a file's contents decide its format, whatever it is named, and an HTML bookmark file gives its web pages as favorites in file order, with its folders flattened, its character references decoded, and markup left out of the names.
import Foundation
import Testing
@testable import Import

@Suite struct ImportedFileTests {
    @Test func anHTMLBookmarkFileGivesItsWebPagesInFileOrder() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let file = try folder.write(Data("""
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
            <TITLE>Bookmarks</TITLE>
            <H1>Bookmarks</H1>
            <DL><p>
                <DT><A HREF="https://a.example/" ADD_DATE="1">A&nbsp;&amp;&nbsp;&lt;B&gt;</A>
                <DT><H3>Folder</H3>
                <DL><p>
                    <DT><a href='https://b.example/?q=1&amp;r=2'>B <b>bold</b></a>
                    <DT><A HREF=https://c.example/>&#67;&#x2019;s page &copy;</A>
                    <DT><A HREF="javascript:void(0)">Bookmarklet</A>
                </DL><p>
                <DT><A HREF="file:///tmp/page.html">File</A>
                <DT><A HREF="https://d.example/"></A>
            </DL><p>
            """.utf8), to: "bookmarks.txt")
        let favorites = try ImportedFile.read(file).favorites
        #expect(favorites.map(\.url.absoluteString) == ["https://a.example/", "https://b.example/?q=1&r=2", "https://c.example/", "https://d.example/"])
        #expect(favorites.map(\.title) == ["A & <B>", "B bold", "C\u{2019}s page &copy;", "d.example"])
    }

    @Test func theContentsDecideTheFormatAndAnHTMLFileNeedsNoHeader() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let history = try folder.database("History", [
            ChromiumDatabases.urlsTable,
            "INSERT INTO urls (url, title, visit_count, typed_count, last_visit_time, hidden) VALUES ('https://a.example/', 'A', 3, 0, 12622780800000000, 0)",
        ])
        let read = try ImportedFile.read(history)
        #expect(read.history.map(\.url.absoluteString) == ["https://a.example/"])
        #expect(read.favorites.isEmpty)
        let json = try folder.writeJSON(ChromiumBookmarks.file(bar: [ChromiumBookmarks.url("b", "B", "https://b.example/")]), to: "Bookmarks.plist")
        #expect(try ImportedFile.read(json).favorites.map(\.title) == ["B"])
        let page = try folder.write(Data(#"<p><a href="https://c.example/">C</a></p>"#.utf8), to: "links.html")
        #expect(try ImportedFile.read(page).favorites.map(\.title) == ["C"])
    }

    @Test func aFileInNoFormatIsRefused() throws {
        let folder = try TemporaryFolder()
        defer { folder.remove() }
        let notes = try folder.write(Data(#"Remember <a href="https://a.example/">this</a>."#.utf8), to: "notes.txt")
        #expect(throws: ImportError.unrecognizedFormat(notes)) { try ImportedFile.read(notes) }
    }
}
