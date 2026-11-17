import Foundation

struct Fail: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private final class Box<T>: @unchecked Sendable { var value: T? }

/// Blocks until a callback-style API delivers its value.
func wait<T>(_ start: (@escaping (T) -> Void) -> Void) -> T {
    let box = Box<T>(), done = DispatchSemaphore(value: 0)
    start { box.value = $0; done.signal() }
    done.wait()
    return box.value!
}

// MARK: - Tools

struct Param {
    let name: String, type: String, desc: String, required: Bool
}

func p(_ name: String, _ desc: String, _ type: String = "string", required: Bool = false) -> Param {
    Param(name: name, type: type, desc: desc, required: required)
}

enum Effect { case read, write, destructive }

struct Tool {
    let name: String, summary: String, effect: Effect, params: [Param]
    let run: (Args) throws -> Any

    init(_ name: String, _ summary: String, _ effect: Effect = .read, _ params: [Param] = [], run: @escaping (Args) throws -> Any) {
        self.name = name; self.summary = summary; self.effect = effect; self.params = params; self.run = run
    }

    var schema: [String: Any] {
        var properties: [String: Any] = [:]
        for param in params {
            var property: [String: Any] = ["description": param.desc]
            if param.type == "strings" {
                property["type"] = "array"
                property["items"] = ["type": "string"]
            } else {
                property["type"] = param.type
            }
            properties[param.name] = property
        }
        return [
            "name": name,
            "description": summary,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": params.filter(\.required).map(\.name),
            ] as [String: Any],
            "annotations": [
                "readOnlyHint": effect == .read,
                "destructiveHint": effect == .destructive,
            ],
        ]
    }
}

struct Args {
    let raw: [String: Any]
    init(_ raw: [String: Any]) { self.raw = raw }

    func has(_ key: String) -> Bool { raw[key] != nil && !(raw[key] is NSNull) }
    func str(_ key: String) -> String? { raw[key] as? String }
    func bool(_ key: String) -> Bool? { raw[key] as? Bool }
    func int(_ key: String) -> Int? { (raw[key] as? NSNumber)?.intValue ?? (raw[key] as? String).flatMap(Int.init) }

    func req(_ key: String) throws -> String {
        guard let value = str(key), !value.isEmpty else { throw Fail("Missing required argument: \(key)") }
        return value
    }

    func list(_ key: String) -> [String] {
        if let many = raw[key] as? [String] { return many }
        return str(key).map { [$0] } ?? []
    }

    func date(_ key: String) throws -> Moment? {
        guard let text = str(key), !text.isEmpty else { return nil }
        guard let moment = Moment(text) else {
            throw Fail("Can't read \(key) \"\(text)\". Use ISO 8601, e.g. 2026-03-09 or 2026-03-09T14:30.")
        }
        return moment
    }
}

// MARK: - Dates

/// A parsed date argument; `timed` is false when only a day was given.
struct Moment {
    let date: Date, timed: Bool

    init?(_ text: String) {
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [.withInternetDateTime, [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { self.date = date; timed = true; return }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: text) { self.date = date; timed = format != "yyyy-MM-dd"; return }
        }
        return nil
    }
}

func stamp(_ date: Date) -> String {
    let iso = ISO8601DateFormatter()
    iso.timeZone = .current
    return iso.string(from: date)
}

func day(_ date: Date) -> String {
    let local = DateFormatter()
    local.locale = Locale(identifier: "en_US_POSIX")
    local.dateFormat = "yyyy-MM-dd"
    return local.string(from: date)
}

// MARK: - Output

/// Builds a JSON object, leaving out nil and empty values.
func object(_ pairs: KeyValuePairs<String, Any?>) -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, value) in pairs {
        switch value {
        case nil, is NSNull: continue
        case let text as String where text.isEmpty: continue
        case let items as [Any] where items.isEmpty: continue
        case let value?: out[key] = value
        }
    }
    return out
}

private func plain(_ value: Any) -> Any {
    switch value {
    case let date as Date: return stamp(date)
    case let items as [Any]: return items.map(plain)
    case let fields as [String: Any]: return fields.mapValues(plain)
    default: return value
    }
}

func render(_ value: Any) -> String {
    if let text = value as? String { return text }
    let data = try? JSONSerialization.data(withJSONObject: plain(value), options: [.withoutEscapingSlashes, .sortedKeys])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\(value)"
}

func clip(_ text: String, _ limit: Int) -> String {
    text.count <= limit ? text : text.prefix(limit) + "\n… [truncated, \(text.count - limit) more characters]"
}
