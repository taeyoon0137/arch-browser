// JSON-RPC 2.0 messages, the control protocol's envelope and arch-mcp's (docs/agents.md, Local control channel ▸ Framing and methods; arch-mcp). Batches are not part of either, so an array reads as an invalid request.
import Foundation

/// A request's ID: JSON-RPC allows a number or a string.
public enum AgentRPCID: Hashable, Sendable {
    case number(Int)
    case string(String)

    public var json: AgentJSON {
        switch self {
        case .number(let number): return .number(Double(number))
        case .string(let string): return .string(string)
        }
    }

    init?(_ json: AgentJSON) {
        switch json {
        case .number(let number) where number.rounded() == number && abs(number) < 1e15: self = .number(Int(number))
        case .string(let string): self = .string(string)
        default: return nil
        }
    }
}

public struct AgentRPCError: Error, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: AgentJSON?

    public init(code: Int, message: String, data: AgentJSON? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let parseErrorCode = -32700
    public static let invalidRequestCode = -32600
    public static let methodNotFoundCode = -32601
    public static let invalidParamsCode = -32602
    public static let internalErrorCode = -32603

    public static func parseError(_ message: String = "The message is not valid JSON.") -> AgentRPCError { AgentRPCError(code: parseErrorCode, message: message) }
    public static func invalidRequest(_ message: String) -> AgentRPCError { AgentRPCError(code: invalidRequestCode, message: message) }
    public static func methodNotFound(_ method: String) -> AgentRPCError { AgentRPCError(code: methodNotFoundCode, message: "Method not found: \(method)") }
    public static func invalidParams(_ message: String) -> AgentRPCError { AgentRPCError(code: invalidParamsCode, message: message) }
    public static func internalError(_ message: String) -> AgentRPCError { AgentRPCError(code: internalErrorCode, message: message) }
}

public enum AgentRPCMessage: Equatable, Sendable {
    case request(id: AgentRPCID, method: String, params: AgentJSON?)
    case notification(method: String, params: AgentJSON?)
    case result(id: AgentRPCID, result: AgentJSON)
    /// An error answer. The ID is nil when the request's ID could not be read, as for a parse error.
    case error(id: AgentRPCID?, error: AgentRPCError)

    public func encoded() throws -> Data {
        var object: [String: AgentJSON] = ["jsonrpc": "2.0"]
        switch self {
        case .request(let id, let method, let params):
            object["id"] = id.json
            object["method"] = .string(method)
            object["params"] = params
        case .notification(let method, let params):
            object["method"] = .string(method)
            object["params"] = params
        case .result(let id, let result):
            object["id"] = id.json
            object["result"] = result
        case .error(let id, let error):
            object["id"] = id?.json ?? .null
            var errorObject: [String: AgentJSON] = ["code": .number(Double(error.code)), "message": .string(error.message)]
            errorObject["data"] = error.data
            object["error"] = .object(errorObject)
        }
        return try AgentJSON.object(object).encoded()
    }

    /// Reads one message. Throws a parse error for text that is not JSON and an invalid request for JSON that is not a JSON-RPC 2.0 message.
    public static func decode(_ data: Data) throws -> AgentRPCMessage {
        guard let json = try? AgentJSON.decode(data) else { throw AgentRPCError.parseError() }
        guard case .object(let object) = json else { throw AgentRPCError.invalidRequest("A message must be a JSON object.") }
        guard object["jsonrpc"] == "2.0" else { throw AgentRPCError.invalidRequest("The message's jsonrpc member must be \"2.0\".") }
        let params = object["params"]
        switch params {
        case nil, .object?, .array?: break
        default: throw AgentRPCError.invalidRequest("A message's params must be an object or an array.")
        }
        if let method = object["method"] {
            guard let name = method.stringValue else { throw AgentRPCError.invalidRequest("A message's method must be a string.") }
            guard let idValue = object["id"] else { return .notification(method: name, params: params) }
            guard let id = AgentRPCID(idValue) else { throw AgentRPCError.invalidRequest("A request's id must be a string or an integer.") }
            return .request(id: id, method: name, params: params)
        }
        let result = object["result"]
        let error = object["error"]
        guard (result == nil) != (error == nil) else { throw AgentRPCError.invalidRequest("An answer must carry either result or error.") }
        let id = object["id"].flatMap(AgentRPCID.init)
        if let result {
            guard let id else { throw AgentRPCError.invalidRequest("A result must carry the request's id.") }
            return .result(id: id, result: result)
        }
        guard case .object(let errorObject)? = error,
              case .number(let code)? = errorObject["code"], code.rounded() == code,
              let message = errorObject["message"]?.stringValue
        else { throw AgentRPCError.invalidRequest("An error must carry an integer code and a message.") }
        return .error(id: id, error: AgentRPCError(code: Int(code), message: message, data: errorObject["data"]))
    }
}
