// GitHub searches through the user's `gh` (docs/bookmarks.md, Live folders ▸ GitHub; live folder rule 3). `gh` keeps its own sign-in, made with `gh auth login` in the built-in terminal. Arch runs only `gh auth status` and `gh api graphql` with a fixed query, sends the search on standard input, and never asks `gh` for its token or reads its files.
import AI
import Foundation

public enum GitHubCLIStatus: Equatable, Sendable {
    case notInstalled
    case signedOut
    case signedIn
}

public actor GitHubCLI {
    public static let shared = GitHubCLI()

    /// The query every search sends, with the search and the item limit as variables.
    public static let query = """
    query($q: String!, $n: Int!) {
      search(query: $q, type: ISSUE, first: $n) {
        nodes {
          __typename
          ... on PullRequest {
            number title url updatedAt state isDraft reviewDecision mergeable
            repository { nameWithOwner } author { login }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          }
          ... on Issue { number title url updatedAt state repository { nameWithOwner } author { login } }
        }
      }
      rateLimit { resetAt }
    }
    """

    /// How long a rate-limited search waits when GitHub names no reset.
    public static let rateLimitWait: TimeInterval = 15 * 60
    private static let messageLimit = 200

    private let shell: LoginShell
    private let executableName: String
    private let timeLimit: Duration
    private let outputLimit: Int
    private var executable: URL?

    /// Tests pass a login shell that stands in for the user's, and shorter limits.
    public init(shell: LoginShell = .shared, executableName: String = "gh", timeLimit: Duration = .seconds(30), outputLimit: Int = 8 * 1_024 * 1_024) {
        self.shell = shell
        self.executableName = executableName
        self.timeLimit = timeLimit
        self.outputLimit = outputLimit
    }

    /// `gh` in the login shell's PATH, looked up once per launch, and again with `again` (Check Again) or once the file is gone.
    public func locate(again: Bool = false) async -> URL? {
        if !again, let executable, AICommandLineConfiguration.isExecutable(at: executable) { return executable }
        executable = await shell.locateExecutable(named: executableName)
        return executable
    }

    /// `gh auth status --hostname <host>`: exit 0 is signed in, any other ending is signed out.
    public func status(host: String) async -> GitHubCLIStatus {
        guard GitHubSearch.isValidHost(host) else { return .signedOut }
        do {
            let run = try await run(["auth", "status", "--hostname", host], input: Data())
            return run.termination == .exited(0) ? .signedIn : .signedOut
        } catch LiveFolderError.gitHubNotInstalled {
            return .notInstalled
        } catch {
            return .signedOut
        }
    }

    /// The first `limit` results of `search`, in GitHub's order, which the built-in searches sort by the latest update. Throws `LiveFolderError`: signed out at exit 4, GitHub's or `gh`'s message at exit 1, `rateLimited` for a `RATE_LIMITED` error, and the limits.
    public func search(_ search: GitHubSearch, limit: Int) async throws -> [LiveItem] {
        guard GitHubSearch.isValidHost(search.host) else { throw LiveFolderError.gitHubFailed("\(search.host) is not a GitHub host.") }
        let body: [String: Any] = ["query": Self.query, "variables": ["q": search.query, "n": limit]]
        let input = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let run = try await run(["api", "graphql", "--hostname", search.host, "--input", "-"], input: input)
        return try Self.items(from: run, host: search.host)
    }

    // MARK: Running

    private struct Run {
        var termination: CommandLineTermination
        var output: Data
        var errorLine: String?
    }

    /// Runs `gh` in a new empty folder under TMPDIR, removed afterward, ending it at the time limit, at the output limit, or when the task is cancelled.
    private func run(_ arguments: [String], input: Data) async throws -> Run {
        guard let executable = await locate() else { throw LiveFolderError.gitHubNotInstalled }
        let environment = await environment()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Arch-gh-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LiveFolderError.gitHubFailed("gh could not start: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let process: CommandLineProcess
        do {
            process = try CommandLineProcess(executable: executable, arguments: arguments, environment: environment, directory: directory, input: input)
        } catch let error as POSIXError where error.code == .ENOENT {
            self.executable = nil
            throw LiveFolderError.gitHubNotInstalled
        } catch {
            throw LiveFolderError.gitHubFailed("gh could not start: \(error.localizedDescription)")
        }
        let timeLimit = timeLimit, outputLimit = outputLimit
        let deadline = Task { () -> Bool in
            guard (try? await Task.sleep(for: timeLimit)) != nil else { return false }
            process.terminate()
            return true
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            var output = Data()
            for await chunk in process.output {
                output.append(chunk)
                if output.count > outputLimit {
                    process.terminate()
                    throw LiveFolderError.tooLarge(bytes: outputLimit)
                }
            }
            let termination = await process.termination()
            try Task.checkCancellation()
            deadline.cancel()
            if await deadline.value { throw LiveFolderError.timedOut }
            return Run(termination: termination, output: output, errorLine: termination == .exited(0) ? nil : await process.lastErrorLine())
        } onCancel: {
            process.terminate()
        }
    }

    /// The minimal environment of command-line tools, with the login shell's PATH, `gh`'s settings for running without a person at a terminal, and `GH_CONFIG_DIR` and `XDG_CONFIG_HOME` when the login shell sets them, so `gh` finds the sign-in that `gh auth login` wrote from the built-in terminal. No other variable of the shell is passed, so token variables such as `GH_TOKEN` never reach `gh`.
    private func environment() async -> [String: String] {
        var environment = LoginShell.baseEnvironment
        let variables = await shell.variables()
        if let path = variables?.path { environment["PATH"] = path }
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["NO_COLOR"] = "1"
        if let folder = variables?.gitHubConfigDirectory { environment["GH_CONFIG_DIR"] = folder }
        if let folder = variables?.configHome { environment["XDG_CONFIG_HOME"] = folder }
        return environment
    }

    // MARK: Reading the response

    private struct Response: Decodable {
        struct Payload: Decodable {
            var search: Search?
            var rateLimit: RateLimit?
        }

        struct Search: Decodable {
            var nodes: [Node?]
        }

        struct RateLimit: Decodable {
            var resetAt: String?
        }

        struct Problem: Decodable {
            var type: String?
            var message: String?
        }

        var data: Payload?
        var errors: [Problem]?
    }

    private struct Node: Decodable {
        struct Repository: Decodable { var nameWithOwner: String }
        struct Author: Decodable { var login: String }
        struct Commits: Decodable {
            struct Entry: Decodable {
                struct Commit: Decodable {
                    struct Rollup: Decodable { var state: String? }
                    var statusCheckRollup: Rollup?
                }

                var commit: Commit
            }

            var nodes: [Entry?]
        }

        var __typename: String
        var number: Int?
        var title: String?
        var url: String?
        var updatedAt: String?
        var state: String?
        var isDraft: Bool?
        var reviewDecision: String?
        var mergeable: String?
        var repository: Repository?
        var author: Author?
        var commits: Commits?
    }

    private static func items(from run: Run, host: String) throws -> [LiveItem] {
        if run.termination == .exited(4) { throw LiveFolderError.gitHubSignedOut(host: host) }
        let response = try? JSONDecoder().decode(Response.self, from: run.output)
        let problems = response?.errors ?? []
        if problems.contains(where: { $0.type == "RATE_LIMITED" }) {
            let reset = response?.data?.rateLimit?.resetAt.flatMap { try? Date.ISO8601FormatStyle().parse($0) }
            throw LiveFolderError.rateLimited(until: reset ?? Date().addingTimeInterval(rateLimitWait))
        }
        if run.termination == .exited(0), problems.isEmpty, let nodes = response?.data?.search?.nodes {
            return nodes.compactMap { $0.flatMap(item) }
        }
        if let message = problems.compactMap(\.message).first(where: { !$0.isEmpty }) {
            throw LiveFolderError.gitHubFailed(String(message.prefix(messageLimit)))
        }
        switch run.termination {
        case .exited(0): throw LiveFolderError.gitHubFailed("gh printed an answer Arch cannot read.")
        case .exited(let code): throw LiveFolderError.gitHubFailed(String((run.errorLine ?? "gh exited with status \(code).").prefix(messageLimit)))
        case .signaled(let signal): throw LiveFolderError.gitHubFailed(String((run.errorLine ?? "gh stopped on signal \(signal).").prefix(messageLimit)))
        }
    }

    /// A pull request or issue as an item, whose ID is its address. Other nodes, and nodes without an `http` or `https` address, are left out.
    private static func item(_ node: Node) -> LiveItem? {
        let kind: GitHubItem.Kind
        switch node.__typename {
        case "PullRequest": kind = .pullRequest
        case "Issue": kind = .issue
        default: return nil
        }
        guard let address = node.url, let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let number = node.number, let repository = node.repository?.nameWithOwner else { return nil }
        let state: GitHubItem.State
        switch node.state {
        case "MERGED": state = .merged
        case "CLOSED": state = .closed
        default: state = node.isDraft == true ? .draft : .open
        }
        let checks = node.commits?.nodes.compactMap { $0 }.last?.commit.statusCheckRollup?.state
        let gitHub = GitHubItem(kind: kind, state: state, repository: repository, number: number, author: node.author?.login,
                                reviewDecision: node.reviewDecision.flatMap(GitHubItem.ReviewDecision.init(rawValue:)),
                                mergeable: node.mergeable.flatMap(GitHubItem.Mergeable.init(rawValue:)),
                                checks: checks.flatMap(GitHubItem.CheckState.init(rawValue:)))
        let title = FeedText.collapsed(node.title ?? "").nonEmpty ?? gitHub.detail
        return LiveItem(id: address, url: url, title: title, date: node.updatedAt.flatMap { try? Date.ISO8601FormatStyle().parse($0) }, gitHub: gitHub)
    }
}
