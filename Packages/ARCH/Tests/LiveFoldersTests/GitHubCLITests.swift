// `gh` through shell scripts that stand in for it and for the login shell, so the tests run neither the user's shell nor their `gh` (docs/bookmarks.md, Tests ▸ LiveFoldersTests).
import AI
import Foundation
import Testing
@testable import LiveFolders

/// A login shell whose profile prints text and exports variables, tokens among them, before it runs the command it is given. Its PATH starts with `folder`, where the tests put `gh`.
private func loginShell(in folder: URL, exporting exports: String = "") throws -> LoginShell {
    let shell = try script("login-shell", in: folder, """
    echo 'Last login: today'
    export PATH="\(folder.path):/usr/bin:/bin" GH_TOKEN=token-from-profile GITHUB_TOKEN=token-from-profile \(exports)
    exec /bin/sh -c "$4"
    """)
    return LoginShell(executable: shell)
}

/// A stand-in for `gh` in `folder` that records its arguments, standard input, and environment there, then runs `body`.
private func gh(in folder: URL, _ body: String) throws {
    try script("gh", in: folder, """
    printf '%s\\n' "$@" > '\(folder.path)/arguments'
    cat > '\(folder.path)/input'
    env > '\(folder.path)/environment'
    \(body)
    """)
}

/// `gh` printing `json` and exiting with `status`.
private func answer(_ json: String, status: Int = 0) -> String {
    "cat <<'JSON'\n\(json)\nJSON\nexit \(status)"
}

private func recorded(_ name: String, in folder: URL) throws -> String {
    try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
}

/// The variables `gh` saw, without those its own shell sets.
private func environment(in folder: URL) throws -> [String: String] {
    var variables: [String: String] = [:]
    for line in try recorded("environment", in: folder).split(separator: "\n") {
        guard let separator = line.firstIndex(of: "=") else { continue }
        variables[String(line[..<separator])] = String(line[line.index(after: separator)...])
    }
    for name in ["PWD", "SHLVL", "_"] { variables[name] = nil }
    return variables
}

private func searchError(_ cli: GitHubCLI, _ search: GitHubSearch = GitHubSearch(kind: .myPullRequests)) async -> LiveFolderError? {
    do {
        _ = try await cli.search(search, limit: 25)
        return nil
    } catch {
        return error as? LiveFolderError
    }
}

private let searchResponse = """
{"data":{"search":{"nodes":[
 {"__typename":"PullRequest","number":12,"title":"Add  live\\nfolders","url":"https://github.com/owner/repo/pull/12","updatedAt":"2026-11-13T10:00:00Z","state":"OPEN","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","mergeable":"CONFLICTING","repository":{"nameWithOwner":"owner/repo"},"author":{"login":"octo"},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}},
 {"__typename":"PullRequest","number":13,"title":"Draft","url":"https://github.com/owner/repo/pull/13","updatedAt":"2026-11-12T10:00:00Z","state":"OPEN","isDraft":true,"reviewDecision":null,"mergeable":"UNKNOWN","repository":{"nameWithOwner":"owner/repo"},"author":{"login":"octo"},"commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}},
 {"__typename":"PullRequest","number":9,"title":"Merged","url":"https://github.com/owner/repo/pull/9","updatedAt":"2026-11-11T10:00:00Z","state":"MERGED","isDraft":false,"reviewDecision":"APPROVED","mergeable":"UNKNOWN","repository":{"nameWithOwner":"owner/repo"},"author":null,"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}},
 {"__typename":"Issue","number":4,"title":"Bug","url":"https://github.com/owner/other/issues/4","updatedAt":"2026-11-10T10:00:00Z","state":"CLOSED","repository":{"nameWithOwner":"owner/other"},"author":{"login":"someone"}},
 {"__typename":"Discussion"},
 null
]},"rateLimit":{"resetAt":"2026-11-13T11:00:00Z"}}}
"""

/// A `gh` that a regression leaves running fails its test at the time limit instead of stopping the run.
@Suite(.timeLimit(.minutes(1))) struct GitHubCLITests {
    @Test func searchesWithTheFixedQueryOnStandardInputOnly() async throws {
        let folder = try temporaryDirectory()
        try gh(in: folder, answer(searchResponse))
        let cli = GitHubCLI(shell: try loginShell(in: folder))
        let search = GitHubSearch(host: "github.com", kind: .search, text: "repo:owner/secret-project is:open")
        let items = try await cli.search(search, limit: 25)

        let arguments = try recorded("arguments", in: folder).split(separator: "\n").map(String.init)
        #expect(arguments == ["api", "graphql", "--hostname", "github.com", "--input", "-"])
        let input = try #require(try JSONSerialization.jsonObject(with: Data(recorded("input", in: folder).utf8)) as? [String: Any])
        #expect(input["query"] as? String == GitHubCLI.query)
        let variables = try #require(input["variables"] as? [String: Any])
        #expect(variables["q"] as? String == "repo:owner/secret-project is:open sort:updated-desc")
        #expect(variables["n"] as? Int == 25)

        #expect(items.map(\.id) == ["https://github.com/owner/repo/pull/12", "https://github.com/owner/repo/pull/13", "https://github.com/owner/repo/pull/9", "https://github.com/owner/other/issues/4"])
        #expect(items[0].title == "Add live folders")
        #expect(items[0].date == (try Date.ISO8601FormatStyle().parse("2026-11-13T10:00:00Z")))
        #expect(items[0].gitHub == GitHubItem(kind: .pullRequest, state: .open, repository: "owner/repo", number: 12, author: "octo", reviewDecision: .reviewRequired, mergeable: .conflicting, checks: .failure))
        #expect(items[0].gitHub?.detail == "owner/repo #12 · octo")
        #expect(items[1].gitHub?.state == .draft)
        #expect(items[1].gitHub?.checks == nil)
        #expect(items[1].gitHub?.mergeable == .unknown)
        #expect(items[2].gitHub?.state == .merged)
        #expect(items[2].gitHub?.reviewDecision == .approved)
        #expect(items[2].gitHub?.checks == .success)
        #expect(items[2].gitHub?.detail == "owner/repo #9")
        #expect(items[3].gitHub == GitHubItem(kind: .issue, state: .closed, repository: "owner/other", number: 4, author: "someone"))
    }

    @Test func runsWithOnlyTheListedVariables() async throws {
        let folder = try temporaryDirectory()
        try gh(in: folder, answer(searchResponse))
        let cli = GitHubCLI(shell: try loginShell(in: folder, exporting: "GH_CONFIG_DIR=/Users/test/gh-config XDG_CONFIG_HOME=/Users/test/config"))
        _ = try await cli.search(GitHubSearch(kind: .reviewRequests), limit: 10)
        let variables = try environment(in: folder)
        #expect(Set(variables.keys) == ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "LANG", "TMPDIR", "TERM", "GH_PROMPT_DISABLED", "GH_NO_UPDATE_NOTIFIER", "NO_COLOR", "GH_CONFIG_DIR", "XDG_CONFIG_HOME"])
        #expect(variables["PATH"] == "\(folder.path):/usr/bin:/bin")
        #expect(variables["GH_CONFIG_DIR"] == "/Users/test/gh-config")
        #expect(variables["XDG_CONFIG_HOME"] == "/Users/test/config")
        #expect(variables["GH_PROMPT_DISABLED"] == "1")
        #expect(variables["TERM"] == "dumb")
        #expect(variables["GH_TOKEN"] == nil && variables["GITHUB_TOKEN"] == nil)
    }

    @Test func leavesOutConfigurationFoldersTheShellDoesNotSetAsAbsolutePaths() async throws {
        let folder = try temporaryDirectory()
        try gh(in: folder, "exit 0")
        let cli = GitHubCLI(shell: try loginShell(in: folder, exporting: "XDG_CONFIG_HOME=relative/config"))
        #expect(await cli.status(host: "github.com") == .signedIn)
        let variables = try environment(in: folder)
        #expect(variables["GH_CONFIG_DIR"] == nil)
        #expect(variables["XDG_CONFIG_HOME"] == nil)
        #expect(variables["GH_TOKEN"] == nil && variables["GITHUB_TOKEN"] == nil)
    }

    @Test func statusFollowsTheExitStatus() async throws {
        let signedIn = try temporaryDirectory()
        try gh(in: signedIn, "exit 0")
        #expect(await GitHubCLI(shell: try loginShell(in: signedIn)).status(host: "github.example.com") == .signedIn)
        #expect(try recorded("arguments", in: signedIn).split(separator: "\n") == ["auth", "status", "--hostname", "github.example.com"])

        let signedOut = try temporaryDirectory()
        try gh(in: signedOut, "echo 'You are not logged into any GitHub hosts.' >&2\nexit 1")
        #expect(await GitHubCLI(shell: try loginShell(in: signedOut)).status(host: "github.com") == .signedOut)

        let missing = try temporaryDirectory()
        #expect(await GitHubCLI(shell: try loginShell(in: missing)).status(host: "github.com") == .notInstalled)
    }

    @Test func findsGhAgainOnceItsFileIsGone() async throws {
        let folder = try temporaryDirectory()
        try gh(in: folder, "exit 0")
        let cli = GitHubCLI(shell: try loginShell(in: folder))
        #expect(await cli.locate()?.path == folder.appendingPathComponent("gh").path)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("gh"))
        #expect(await cli.locate() == nil)
        #expect(await searchError(cli) == .gitHubNotInstalled)
    }

    @Test func exitStatusFourIsSignedOut() async throws {
        let folder = try temporaryDirectory()
        try gh(in: folder, "echo 'To get started with GitHub CLI, please run:  gh auth login' >&2\nexit 4")
        #expect(await searchError(GitHubCLI(shell: try loginShell(in: folder)), GitHubSearch(host: "github.example.com", kind: .assignedIssues)) == .gitHubSignedOut(host: "github.example.com"))
    }

    @Test func exitStatusOneShowsGitHubsMessageOrTheLastLineOfStandardError() async throws {
        let errors = try temporaryDirectory()
        try gh(in: errors, answer(#"{"errors":[{"type":"INVALID","message":"Something went wrong while executing your query."},{"message":"Second"}]}"#, status: 1))
        #expect(await searchError(GitHubCLI(shell: try loginShell(in: errors))) == .gitHubFailed("Something went wrong while executing your query."))

        let standardError = try temporaryDirectory()
        let long = String(repeating: "x", count: 300)
        try gh(in: standardError, "echo 'first line' >&2\necho 'gh: \(long)' >&2\nexit 1")
        guard case .gitHubFailed(let message) = await searchError(GitHubCLI(shell: try loginShell(in: standardError))) else {
            Issue.record("Expected gh's message")
            return
        }
        #expect(message.hasPrefix("gh: xxx"))
        #expect(message.count == 200)
    }

    @Test func aRateLimitWaitsForItsReset() async throws {
        let withReset = try temporaryDirectory()
        try gh(in: withReset, answer(#"{"data":{"search":null,"rateLimit":{"resetAt":"2026-11-13T11:00:00Z"}},"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#, status: 1))
        #expect(await searchError(GitHubCLI(shell: try loginShell(in: withReset))) == .rateLimited(until: try Date.ISO8601FormatStyle().parse("2026-11-13T11:00:00Z")))

        let withoutReset = try temporaryDirectory()
        try gh(in: withoutReset, answer(#"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#, status: 1))
        let before = Date()
        guard case .rateLimited(let until) = await searchError(GitHubCLI(shell: try loginShell(in: withoutReset))) else {
            Issue.record("Expected a rate limit")
            return
        }
        #expect(until.timeIntervalSince(before) >= GitHubCLI.rateLimitWait - 1)
        #expect(until.timeIntervalSince(before) < GitHubCLI.rateLimitWait + 30)
    }

    @Test func endsGhAtTheTimeLimit() async throws {
        let folder = try temporaryDirectory()
        try gh(in: folder, "sleep 30")
        let start = ContinuousClock.now
        #expect(await searchError(GitHubCLI(shell: try loginShell(in: folder), timeLimit: .milliseconds(300))) == .timedOut)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func endsGhAtTheOutputLimit() async throws {
        let folder = try temporaryDirectory()
        try gh(in: folder, "yes a | head -c 5000\nsleep 30")
        let start = ContinuousClock.now
        #expect(await searchError(GitHubCLI(shell: try loginShell(in: folder), outputLimit: 1_000)) == .tooLarge(bytes: 1_000))
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func refusesHostsThatAreNoHostNames() async throws {
        #expect(GitHubSearch.isValidHost("github.com"))
        #expect(GitHubSearch.isValidHost("git.example.org:8443"))
        #expect(!GitHubSearch.isValidHost("--hostname"))
        #expect(!GitHubSearch.isValidHost("github.com/evil"))
        #expect(!GitHubSearch.isValidHost("host:"))
        #expect(!GitHubSearch.isValidHost(""))
        let folder = try temporaryDirectory()
        try gh(in: folder, "exit 0")
        #expect(await GitHubCLI(shell: try loginShell(in: folder)).status(host: "-x") == .signedOut)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("arguments").path))
    }
}
