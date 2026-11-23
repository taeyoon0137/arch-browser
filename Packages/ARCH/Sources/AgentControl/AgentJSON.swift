// A JSON value for the parts of control messages whose shape the message does not fix: JSON-RPC params and results, tool arguments, and JSON Schemas (docs/agents.md, Local control channel ▸ Framing and methods).
import Foundation

/// JSON values used by control messages with dynamic params and results.
public enum AgentJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgentJSON])
    case object([String: AgentJSON])

    /// The value as compact UTF-8 JSON with sorted keys, so that equal values give equal bytes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> AgentJSON {
        try JSONDecoder().decode(AgentJSON.self, from: data)
    }

    /// The value converted to a `Decodable` type through its JSON.
    public func decode<Value: Decodable>(as type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: encoded())
    }

    /// A `Encodable` value as JSON.
    public init<Value: Encodable>(encoding value: Value) throws {
        self = try AgentJSON.decode(JSONEncoder().encode(value))
    }

    public subscript(key: String) -> AgentJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    public var objectValue: [String: AgentJSON]? {
        if case .object(let object) = self { return object }
        return nil
    }
}

extension AgentJSON: Codable {
    /// Decodes one JSON value, including nested arrays and objects.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([AgentJSON].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: AgentJSON].self))
        }
    }

    /// Encodes the value as a JSON scalar, array, or object.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

extension AgentJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: AgentJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, AgentJSON)...) { self = .object(Dictionary(elements) { _, last in last }) }
    public init(nilLiteral: ()) { self = .null }
}
