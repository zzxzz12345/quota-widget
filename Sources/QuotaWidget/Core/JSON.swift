import Foundation

/// Thin wrapper over `JSONSerialization` output so providers can walk unknown
/// upstream payloads without declaring a `Codable` type for every variant.
struct JSON {
    let raw: Any

    init(_ raw: Any) {
        self.raw = raw
    }

    static func parse(_ data: Data) throws -> JSON {
        guard !data.isEmpty else { return JSON([String: Any]()) }
        return JSON(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    private static func unwrap(_ value: Any) -> Any {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return mirror.children.first.map { unwrap($0.value) } ?? NSNull()
        }
        return value
    }

    static func isNull(_ value: Any) -> Bool {
        unwrap(value) is NSNull
    }

    static func dictionary(_ value: Any) -> [String: Any]? {
        unwrap(value) as? [String: Any]
    }

    static func array(_ value: Any) -> [Any]? {
        unwrap(value) as? [Any]
    }

    /// `NSNumber` bridges booleans and numbers identically, so probe the
    /// CoreFoundation type before trusting a numeric cast.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    var string: String? {
        let value = JSON.unwrap(raw)
        if let text = value as? String { return text }
        if let number = value as? NSNumber, !JSON.isBoolean(number) { return number.stringValue }
        return nil
    }

    var double: Double? {
        let value = JSON.unwrap(raw)
        if let number = value as? NSNumber, !JSON.isBoolean(number) { return number.doubleValue }
        if let text = value as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    var int: Int? {
        guard let value = double else { return nil }
        return Int(value)
    }

    var bool: Bool? {
        let value = JSON.unwrap(raw)
        if let number = value as? NSNumber, JSON.isBoolean(number) { return number.boolValue }
        if let flag = value as? Bool { return flag }
        return nil
    }

    var object: [String: JSON]? {
        guard let dict = JSON.dictionary(raw) else { return nil }
        return dict.mapValues { JSON($0) }
    }

    var array: [JSON]? {
        guard let items = JSON.array(raw) else { return nil }
        return items.map { JSON($0) }
    }

    var exists: Bool {
        !JSON.isNull(raw)
    }

    subscript(key: String) -> JSON? {
        guard let dict = JSON.dictionary(raw), let value = dict[key] else { return nil }
        return JSON(value)
    }

    subscript(index: Int) -> JSON? {
        guard let items = JSON.array(raw), items.indices.contains(index) else { return nil }
        return JSON(items[index])
    }

    /// Dot-delimited lookup where a numeric segment indexes into an array.
    func path(_ pointer: String) -> JSON? {
        var current = self
        for segment in pointer.split(separator: ".").map(String.init) {
            if let index = Int(segment) {
                guard let next = current[index] else { return nil }
                current = next
            } else {
                guard let next = current[segment] else { return nil }
                current = next
            }
        }
        return current
    }

    func string(at pointer: String) -> String? { path(pointer)?.string }
    func double(at pointer: String) -> Double? { path(pointer)?.double }

    /// First present, parseable value across several candidate pointers.
    func firstString(_ pointers: [String]) -> String? {
        for pointer in pointers {
            if let value = string(at: pointer), !value.isEmpty { return value }
        }
        return nil
    }

    func firstDouble(_ pointers: [String]) -> Double? {
        for pointer in pointers {
            if let value = double(at: pointer) { return value }
        }
        return nil
    }

    func firstArray(_ pointers: [String]) -> [JSON]? {
        for pointer in pointers {
            if let value = path(pointer)?.array { return value }
        }
        return nil
    }
}
