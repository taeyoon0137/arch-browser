// The Claude Code and Codex streams in `Fixtures/Agent` (docs/agents.md, Tests ▸ Fixtures): each recorded stream is JSON lines that end with the turn's last event, and no fixture carries an email address, a home folder path, or a recorded session, thread, message, request, or tool call identifier.
import Foundation
import Testing

private let agentFixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Agent", isDirectory: true)

@Suite struct AgentFixtureTests {
    @Test(arguments: [
        ("claude-session.stdout.jsonl", "result"),
        ("claude-probe.stdout.jsonl", "result"),
        ("claude-ordinary.stdout.jsonl", "result"),
        ("codex-session-first.stdout.jsonl", "turn.completed"),
        ("codex-session-resume.stdout.jsonl", "turn.completed"),
        ("codex-approval-required.stdout.jsonl", "turn.completed"),
        ("codex-ordinary.stdout.jsonl", "turn.completed"),
    ])
    func streamsAreJSONLinesEndingWithTheTurnsLastEvent(file: String, lastType: String) throws {
        let text = try String(contentsOf: agentFixtures.appendingPathComponent(file), encoding: .utf8)
        let types = try text.split(separator: "\n").map { line -> String? in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["type"] as? String
        }
        #expect(!types.isEmpty)
        #expect(!types.contains(nil), "\(file) has a line that is not an event")
        #expect(types.last == lastType)
    }

    @Test func fixturesCarryNoPersonalDetails() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: agentFixtures.path)
        #expect(files.count == 15)
        let email = try Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
        let uuid = try Regex("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
        // The vendors' message, request, and tool call identifiers, which the recording replaced with `msg_fixture01` and so on.
        let vendorIdentifier = try Regex("\\b(msg|req|toolu)_01[A-Za-z0-9]{10,}")
        for file in files {
            let text = try String(contentsOf: agentFixtures.appendingPathComponent(file), encoding: .utf8)
            #expect(text.firstMatch(of: email) == nil, "\(file) has an email address")
            #expect(!text.contains("/Users/"), "\(file) has a home folder path")
            #expect(text.firstMatch(of: vendorIdentifier) == nil, "\(file) has a recorded identifier")
            for match in text.matches(of: uuid) {
                #expect(text[match.range].lowercased().hasPrefix("00000000-0000-4000-8000-"), "\(file) has a recorded identifier")
            }
        }
    }
}
