import Foundation

/// A Sendable JSON value, used to move bridge parameters and results between the main actor and background work.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Converts a value decoded from a WebKit script message (NSNumber, NSString, NSArray, NSDictionary, NSNull).
    public init(bridged value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSONValue.init(bridged:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init(bridged:)))
        default: self = .string(String(describing: value!))
        }
    }

    /// The value in the form WebKit accepts for script message replies.
    public var bridged: Any {
        switch self {
        case .null: NSNull()
        case .bool(let bool): NSNumber(value: bool)
        case .number(let number): NSNumber(value: number)
        case .string(let string): string
        case .array(let array): array.map(\.bridged)
        case .object(let object): object.mapValues(\.bridged)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    public var string: String? {
        if case .string(let string) = self { string } else { nil }
    }

    public var number: Double? {
        if case .number(let number) = self { number } else { nil }
    }

    public var bool: Bool? {
        if case .bool(let bool) = self { bool } else { nil }
    }

    public var object: [String: JSONValue]? {
        if case .object(let object) = self { object } else { nil }
    }
}
