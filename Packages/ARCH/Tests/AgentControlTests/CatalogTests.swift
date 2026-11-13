// The tool catalog against the design's table (docs/agents.md, Tools ▸ Catalog): every tool with its class and notes, names valid for MCP and `AITool`, input schemas that parse with their required parameters among their properties and no top-level combinators, annotations that follow the classes, and the per-call limits in the schemas.
import AgentControl
import Foundation
import Testing

@Suite struct CatalogTests {
    @Test func theCatalogHoldsTheDesignsToolsWithTheirClassesAndNotes() {
        let expected: [(String, AgentToolClass, AgentTool.Traits)] = [
            ("session_info", .reads, []), ("list_spaces", .reads, []), ("list_tabs", .reads, []), ("request_tab", .reads, [.waitsForUser]),
            ("open_tab", .navigates, []), ("navigate", .navigates, []), ("close_tab", .navigates, [.destructive]),
            ("snapshot", .reads, []), ("read_text", .reads, []), ("screenshot", .reads, []),
            ("click", .interacts, []), ("type", .interacts, []), ("press", .interacts, []), ("select_option", .interacts, []),
            ("scroll", .interacts, [.allowedInReadOnly]), ("hover", .interacts, [.allowedInReadOnly]),
            ("wait_for", .reads, []), ("list_downloads", .reads, []), ("search_history", .reads, [.needsHistoryScope]),
            ("ask_user", .reads, [.waitsForUser]), ("request_approval", .sensitive, [.waitsForUser]), ("hand_to_user", .reads, [.waitsForUser]),
            ("approval_wait", .reads, [.waitsForUser]), ("guide", .reads, []),
        ]
        #expect(AgentToolCatalog.tools.map(\.name) == expected.map(\.0))
        for (name, toolClass, traits) in expected {
            let tool = AgentToolCatalog.tool(named: name)
            #expect(tool?.toolClass == toolClass, "\(name)")
            #expect(tool?.traits == traits, "\(name)")
        }
        #expect(AgentToolCatalog.tool(named: "evaluate") == nil)
    }

    @Test func namesAreValidForMCPAndAIToolAndUnique() throws {
        let valid = try Regex("^[a-z0-9_]{1,64}$")
        for tool in AgentToolCatalog.tools {
            #expect(tool.name.wholeMatch(of: valid) != nil, "\(tool.name)")
            for parameter in tool.parameters { #expect(parameter.name.wholeMatch(of: valid) != nil, "\(tool.name).\(parameter.name)") }
            #expect(Set(tool.parameters.map(\.name)).count == tool.parameters.count, "\(tool.name) repeats a parameter")
        }
        #expect(Set(AgentToolCatalog.tools.map(\.name)).count == AgentToolCatalog.tools.count)
    }

    @Test func schemasParseAsObjectsWhoseRequiredParametersAreProperties() throws {
        for tool in AgentToolCatalog.tools {
            let schema = try #require(try JSONSerialization.jsonObject(with: tool.inputSchema.encoded()) as? [String: Any], "\(tool.name)")
            #expect(schema["type"] as? String == "object")
            #expect(schema["additionalProperties"] as? Bool == false)
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect(Set(properties.keys) == Set(tool.parameters.map(\.name)))
            let required = schema["required"] as? [String] ?? []
            #expect(required.allSatisfy { properties[$0] != nil }, "\(tool.name)")
            #expect(Set(required) == Set(tool.parameters.filter(\.isRequired).map(\.name)))
            #expect(schema["required"] == nil || !required.isEmpty, "\(tool.name) lists an empty required array")
            for combinator in ["oneOf", "anyOf", "allOf", "not"] { #expect(schema[combinator] == nil, "\(tool.name) uses \(combinator)") }
            for (name, value) in properties {
                let property = try #require(value as? [String: Any])
                #expect(["string", "integer", "boolean", "array"].contains(property["type"] as? String), "\(tool.name).\(name)")
                #expect(!(property["description"] as? String ?? "").isEmpty, "\(tool.name).\(name)")
            }
        }
    }

    @Test func annotationsFollowTheClasses() {
        for tool in AgentToolCatalog.tools {
            let annotations = tool.annotations
            #expect(annotations["readOnlyHint"] == .bool(tool.toolClass == .reads), "\(tool.name)")
            #expect(annotations["openWorldHint"] == .bool(tool.toolClass == .navigates || tool.toolClass == .interacts), "\(tool.name)")
            #expect(annotations["destructiveHint"] == .bool(tool.name == "close_tab"), "\(tool.name)")
            #expect(tool.mcpDefinition["name"] == .string(tool.name))
            #expect(tool.mcpDefinition["inputSchema"] == tool.inputSchema)
        }
        #expect(AgentToolCatalog.mcpToolList["tools"] == .array(AgentToolCatalog.tools.map(\.mcpDefinition)))
    }

    @Test func schemasCarryThePerCallLimits() throws {
        func maximum(_ tool: String, _ parameter: String) -> Int? {
            AgentToolCatalog.tool(named: tool)?.parameters.first { $0.name == parameter }?.maximum
        }
        #expect(maximum("snapshot", "max_chars") == AgentLimits.snapshotMaximumCharacters)
        #expect(AgentLimits.snapshotMaximumCharacters == 40_000 && AgentLimits.snapshotDefaultCharacters == 16_000)
        #expect(maximum("read_text", "max_chars") == 20_000)
        #expect(maximum("read_text", "offset") == AgentLimits.readTextMaximumCharacters)
        #expect(maximum("wait_for", "timeout_ms") == 30_000)
        #expect(maximum("search_history", "limit") == 20)
        #expect(maximum("click", "count") == 2)
        let snapshot = try #require(AgentToolCatalog.tool(named: "snapshot"))
        #expect(snapshot.inputSchema["properties"]?["max_chars"]?["maximum"] == 40_000)
        #expect(snapshot.parameters.first { $0.name == "max_chars" }?.description.contains("16,000") == true)
    }

    @Test func tabHandlesAndChoicesAreConstrained() throws {
        let navigate = try #require(AgentToolCatalog.tool(named: "navigate"))
        let tab = try #require(navigate.inputSchema["properties"]?["tab"])
        #expect(tab["pattern"] == "^t[1-9][0-9]*$")
        #expect(navigate.inputSchema["required"] == ["tab"])
        #expect(navigate.inputSchema["properties"]?["action"]?["enum"] == ["back", "forward", "reload"])
        let guide = try #require(AgentToolCatalog.tool(named: "guide"))
        #expect(guide.inputSchema["properties"]?["topic"]?["enum"] == .array(AgentGuideTopic.allCases.map { .string($0.rawValue) }))
        let select = try #require(AgentToolCatalog.tool(named: "select_option"))
        #expect(select.inputSchema["properties"]?["values"]?["minItems"] == 1)
    }

    @Test func noToolRunsCodeReadsFilesOrChangesSettings() {
        // Agent decision 6: the catalog has no tool for code, fetches, files, cookies, passwords, the clipboard, or settings.
        let forbidden = ["eval", "javascript", "script", "fetch", "file", "cookie", "password", "clipboard", "setting", "grant", "plugin", "persona"]
        for tool in AgentToolCatalog.tools {
            #expect(!forbidden.contains { tool.name.contains($0) }, "\(tool.name)")
        }
    }
}
