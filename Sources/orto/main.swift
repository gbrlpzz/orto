import Foundation

let version = "0.1.0"

// MARK: - TCC identity
//
// macOS attributes privacy prompts to the "responsible" process, which for a
// stdio server is whatever launched it (Claude Desktop, a terminal). Those apps
// don't declare Calendar/Reminders/Contacts usage, so access would be denied
// without ever prompting. Re-exec once, disclaiming the parent, so that
// Orto.app (and its Info.plist) is the identity macOS asks about.

@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func setDisclaim(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ on: Int32) -> Int32

func disclaimParent() {
    guard Bundle.main.bundleIdentifier != nil, getenv("ORTO_CHILD") == nil,
          let path = Bundle.main.executablePath else { return }
    var environment = ProcessInfo.processInfo.environment
    environment["ORTO_CHILD"] = "1"
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC))
    _ = setDisclaim(&attr, 1)
    let args = CommandLine.arguments.map { strdup($0) } + [nil]
    let env = environment.map { strdup("\($0)=\($1)") } + [nil]
    posix_spawn(nil, path, nil, &attr, args, env)
    // Only reached if the exec failed; carry on undisclaimed.
}

// MARK: - MCP over stdio (newline-delimited JSON-RPC 2.0)

let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

func send(_ message: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func call(_ name: String, _ arguments: [String: Any]) -> (text: String, failed: Bool) {
    guard let tool = tools.first(where: { $0.name == name }) else { return ("Unknown tool: \(name)", true) }
    do {
        return (render(try tool.run(Args(arguments))), false)
    } catch {
        return ((error as? Fail)?.message ?? error.localizedDescription, true)
    }
}

func handle(_ method: String, _ params: [String: Any]) -> [String: Any]? {
    switch method {
    case "initialize":
        let asked = params["protocolVersion"] as? String ?? ""
        return [
            "protocolVersion": protocolVersions.contains(asked) ? asked : protocolVersions[0],
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "orto", "title": "Orto", "version": version],
            "instructions": """
                Orto reads and writes this Mac's Calendar, Reminders, Mail, Notes, Contacts, Messages and Shortcuts. \
                Dates are ISO 8601 in the Mac's local time zone (\(TimeZone.current.identifier)) unless they carry an offset; \
                a date without a time means all-day. Pass ids back exactly as returned. \
                The first use of each app triggers a one-time macOS permission prompt.
                """,
        ]
    case "ping":
        return [:]
    case "tools/list":
        return ["tools": tools.map(\.schema)]
    case "tools/call":
        let (text, failed) = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
        return ["content": [["type": "text", "text": text]], "isError": failed]
    default:
        return nil
    }
}

func serve() {
    while let line = readLine() {
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let method = message["method"] as? String,
              let id = message["id"] else { continue } // notifications need no reply
        if let result = handle(method, message["params"] as? [String: Any] ?? [:]) {
            send(["jsonrpc": "2.0", "id": id, "result": result])
        } else {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }
}

// MARK: - Entry point

disclaimParent()

let argv = CommandLine.arguments
switch argv.count > 1 ? argv[1] : "mcp" {
case "mcp":
    serve()
case "tools":
    for tool in tools { print(tool.name.padding(toLength: 20, withPad: " ", startingAt: 0), tool.summary) }
case "call" where argv.count > 2:
    let json = argv.count > 3 ? argv[3] : "{}"
    guard let arguments = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
        FileHandle.standardError.write(Data("Arguments must be a JSON object\n".utf8))
        exit(2)
    }
    let (text, failed) = call(argv[2], arguments)
    print(text)
    exit(failed ? 1 : 0)
default:
    print("""
        orto \(version) — Apple apps for Claude

          orto                      run the MCP server on stdio
          orto tools                list tools
          orto call <tool> [json]   call one tool, e.g. orto call calendar_events '{"days":3}'
        """)
}
