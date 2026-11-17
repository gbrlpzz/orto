import Foundation

// Notes, Messages and parts of Mail have no framework API, so they are driven
// with AppleScript run in-process. Scripts return positional lists, which are
// decoded into Swift values here; arguments are embedded as escaped literals.

private func code(_ fourCC: String) -> DescType {
    fourCC.utf8.reduce(0) { $0 << 8 | DescType($1) }
}

private func decode(_ descriptor: NSAppleEventDescriptor) -> Any {
    switch descriptor.descriptorType {
    case code("list"):
        return (0..<descriptor.numberOfItems).map { decode(descriptor.atIndex($0 + 1) ?? .null()) }
    case code("true"), code("fals"), code("bool"):
        return descriptor.booleanValue
    case code("long"), code("shor"), code("comp"), code("doub"), code("magn"):
        let number = descriptor.doubleValue
        return number == number.rounded() ? Int(number) : number
    case code("ldt "):
        return descriptor.dateValue ?? NSNull()
    default:
        return descriptor.stringValue ?? NSNull()
    }
}

/// An AppleScript string literal.
func q(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

@discardableResult
func script(_ app: String, _ body: String) throws -> Any {
    let source = "with timeout of 120 seconds\ntell application \"\(app)\"\n\(body)\nend tell\nend timeout"
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error {
        switch error[NSAppleScript.errorNumber] as? Int {
        case -1743: throw Fail("Orto isn't allowed to control \(app). Turn it on in System Settings › Privacy & Security › Automation › Orto.")
        case -1712: throw Fail("\(app) took too long to answer. Try a narrower request.")
        default: throw Fail("\(app): \(error[NSAppleScript.errorMessage] as? String ?? "script failed")")
        }
    }
    return result.map(decode) ?? NSNull()
}

func strings(_ value: Any?) -> [String] {
    (value as? [Any])?.compactMap { $0 as? String } ?? (value as? String).map { [$0] } ?? []
}

// MARK: - Notes

/// Notes stores HTML. Plain text gets light Markdown treatment: #/## headings and - bullets.
private func html(_ text: String) -> String {
    if text.hasPrefix("<") { return text }
    var out = "", inList = false
    for line in text.components(separatedBy: .newlines) {
        let escaped = line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let bullet = escaped.hasPrefix("- ") || escaped.hasPrefix("* ")
        if bullet != inList { out += bullet ? "<ul>" : "</ul>"; inList = bullet }
        if bullet { out += "<li>\(escaped.dropFirst(2))</li>" }
        else if escaped.hasPrefix("## ") { out += "<h2>\(escaped.dropFirst(3))</h2>" }
        else if escaped.hasPrefix("# ") { out += "<h1>\(escaped.dropFirst(2))</h1>" }
        else { out += "<div>\(escaped.isEmpty ? "<br>" : escaped)</div>" }
    }
    return out + (inList ? "</ul>" : "")
}

let noteTools = [
    Tool("notes_search", "Find notes by title or content, most recently edited first. With no query it lists recent notes.", .read, [
        p("query", "Text to find in note titles and bodies"),
        p("limit", "Maximum notes; default 20", "integer"),
    ]) { args in
        let query = args.str("query") ?? ""
        let r = try script("Notes", """
            set hits to {}
            \(query.isEmpty ? "" : "try\nset hits to id of (notes whose plaintext contains \(q(query)))\nend try")
            return {id of notes, name of notes, modification date of notes, hits}
            """) as? [[Any]] ?? []
        guard r.count == 4, r[0].count == r[1].count, r[0].count == r[2].count else { throw Fail("Notes changed while searching; try again.") }
        let bodyHits = Set(strings(r[3]))
        return r[0].indices
            .filter { query.isEmpty || bodyHits.contains(r[0][$0] as? String ?? "") || (r[1][$0] as? String)?.localizedCaseInsensitiveContains(query) == true }
            .sorted { (r[2][$0] as? Date ?? .distantPast) > (r[2][$1] as? Date ?? .distantPast) }
            .prefix(args.int("limit") ?? 20)
            .map { object(["id": r[0][$0], "title": r[1][$0], "modified": r[2][$0]]) }
    },

    Tool("notes_read", "Read a note's text.", .read, [
        p("id", "Note id from notes_search", required: true),
        p("html", "Return the note's HTML instead of plain text (useful before rewriting it with notes_update)", "boolean"),
        p("max_chars", "Truncate after this many characters; default 20000", "integer"),
    ]) { args in
        let r = try script("Notes", """
            set n to note id \(q(try args.req("id")))
            return {name of n, \(args.bool("html") == true ? "body" : "plaintext") of n, creation date of n, modification date of n}
            """) as? [Any] ?? []
        guard r.count == 4 else { throw Fail("Couldn't read that note.") }
        return object(["title": r[0], "created": r[2], "modified": r[3], "body": clip(r[1] as? String ?? "", args.int("max_chars") ?? 20000)])
    },

    Tool("notes_create", "Create a note.", .write, [
        p("title", "Note title", required: true),
        p("body", "Note text. Plain text with optional #/## headings and - bullets, or HTML.", required: true),
        p("folder", "Folder name; defaults to the default Notes folder"),
    ]) { args in
        let title = try args.req("title"), body = "<div><h1>\(title)</h1></div>" + html(try args.req("body"))
        let folder = args.str("folder").flatMap { $0.isEmpty ? nil : " at folder \(q($0))" } ?? ""
        let id = try script("Notes", "return id of (make new note\(folder) with properties {body:\(q(body))})")
        return object(["id": id, "title": title])
    },

    Tool("notes_update", "Add text to the end of a note, or replace its whole body. Replacing drops images and attachments in the note, so prefer append.", .destructive, [
        p("id", "Note id from notes_search", required: true),
        p("append", "Text to add at the end (same format as notes_create body)"),
        p("body", "New full body, including the title as its first line; replaces everything"),
    ]) { args in
        let note = "note id \(q(try args.req("id")))"
        if let body = args.str("body"), !body.isEmpty {
            try script("Notes", "set body of \(note) to \(q(html(body)))")
        } else if let text = args.str("append"), !text.isEmpty {
            try script("Notes", "set body of \(note) to (body of \(note)) & \(q(html(text)))")
        } else {
            throw Fail("Pass append or body.")
        }
        return "Updated"
    },
]

// MARK: - Messages and Shortcuts

private func shortcuts(_ arguments: [String]) throws -> String {
    let process = Process(), out = Pipe(), err = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let problem = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw Fail(problem.isEmpty ? "shortcuts failed" : problem) }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

let otherTools = [
    Tool("messages_send", "Send an iMessage. Only when the user has clearly asked to send it.", .write, [
        p("to", "Phone number (with country code) or Apple ID email", required: true),
        p("text", "Message text", required: true),
    ]) { args in
        let to = try args.req("to")
        try script("Messages", "send \(q(try args.req("text"))) to participant \(q(to)) of (1st account whose service type = iMessage)")
        return "Sent to \(to)"
    },

    Tool("shortcuts_list", "List the user's Shortcuts by name.") { _ in
        try shortcuts(["list"]).split(separator: "\n").map(String.init)
    },

    Tool("shortcuts_run", "Run one of the user's Shortcuts and return its output. Shortcuts can do anything the user built them to do.", .destructive, [
        p("name", "Shortcut name from shortcuts_list", required: true),
        p("input", "Text passed to the shortcut as its input"),
    ]) { args in
        var arguments = ["run", try args.req("name")]
        if let input = args.str("input"), !input.isEmpty {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("orto-\(UUID().uuidString).txt")
            try input.write(to: file, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: file) }
            arguments += ["--input-path", file.path]
            return try shortcuts(arguments)
        }
        let output = try shortcuts(arguments)
        return output.isEmpty ? "Ran \(args.str("name") ?? "")" : output
    },
]

let tools = calendarTools + reminderTools + mailTools + noteTools + contactTools + otherTools
