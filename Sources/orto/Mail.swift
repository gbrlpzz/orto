import Foundation
import SQLite3

// Mail's scripting interface needs seconds per message on a large inbox, so
// searching reads Mail's own index database instead (read-only; this is what
// needs Full Disk Access). Bodies, drafts and changes go through Mail itself,
// which is quick once a message is addressed by id.

private func rows(_ sql: String, _ values: [Any] = []) throws -> [[Any]] {
    let root = NSHomeDirectory() + "/Library/Mail"
    let version = (try? FileManager.default.contentsOfDirectory(atPath: root))?
        .filter { $0.hasPrefix("V") }
        .max { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
    let path = "\(root)/\(version ?? "V10")/MailData/Envelope Index"
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard FileManager.default.isReadableFile(atPath: path), sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        let pane = Process()
        pane.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        pane.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
        try? pane.run()
        throw Fail("Reading mail needs Full Disk Access. In System Settings › Privacy & Security › Full Disk Access (just opened), add and enable Orto (\(Bundle.main.bundlePath)), then try again.")
    }
    sqlite3_busy_timeout(db, 3000)
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw Fail("Mail index: \(String(cString: sqlite3_errmsg(db)))")
    }
    for (index, value) in values.enumerated() {
        if let number = value as? Int {
            sqlite3_bind_int64(statement, Int32(index + 1), Int64(number))
        } else {
            sqlite3_bind_text(statement, Int32(index + 1), "\(value)", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
    var out: [[Any]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        out.append((0..<sqlite3_column_count(statement)).map { column in
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER: return Int(sqlite3_column_int64(statement, column))
            case SQLITE_NULL: return NSNull()
            default: return String(cString: sqlite3_column_text(statement, column))
            }
        })
    }
    return out
}

private struct Mailbox {
    let id: Int, account: String, name: String, total: Int, unread: Int

    // Exchange localises its inbox; IMAP always calls it INBOX.
    static let inboxNames: Set = ["inbox", "posta in arrivo", "posteingang", "boîte de réception", "bandeja de entrada", "caixa de entrada", "postvak in", "inkorgen", "indbakke", "innboks", "saapuneet", "受信トレイ", "收件箱", "收件匣"]
    var isInbox: Bool { Mailbox.inboxNames.contains(name.lowercased()) }

    /// How Mail's scripting interface names this mailbox.
    var reference: String { account.isEmpty ? "mailbox \(q(name))" : "mailbox \(q(name)) of account id \(q(account))" }
}

private func mailboxes() throws -> [Mailbox] {
    try rows("SELECT ROWID, url, total_count, unread_count FROM mailboxes").compactMap { row in
        guard let url = URLComponents(string: row[1] as? String ?? ""), let id = row[0] as? Int else { return nil }
        // "On My Mac" mailboxes belong to no account.
        return Mailbox(id: id, account: url.scheme == "local" ? "" : url.host ?? "", name: String(url.path.dropFirst()),
                       total: row[2] as? Int ?? 0, unread: row[3] as? Int ?? 0)
    }
}

private struct Account {
    let name: String, addresses: [String]
}

private var knownAccounts: [String: Account]?

/// Mail accounts by the id that mailbox URLs use.
private func accounts() throws -> [String: Account] {
    if let knownAccounts { return knownAccounts }
    let r = try script("Mail", "return {id of accounts, name of accounts, email addresses of accounts}") as? [[Any]] ?? []
    guard r.count == 3 else { return [:] }
    var found: [String: Account] = ["": Account(name: "On My Mac", addresses: [])]
    for index in r[0].indices {
        found[r[0][index] as? String ?? ""] = Account(name: r[1][index] as? String ?? "", addresses: strings(r[2][index]))
    }
    knownAccounts = found
    return found
}

/// A reference Mail's scripting interface resolves quickly: the message by id within its own mailbox.
private func message(_ id: String) throws -> String {
    guard let number = Int(id) else { throw Fail("Not a mail id: \(id). Use an id from mail_search.") }
    let home = try rows("SELECT mailbox FROM messages WHERE ROWID = ?", [number]).first?[0] as? Int
    guard let mailbox = try mailboxes().first(where: { $0.id == home }) else { throw Fail("No message with id \(id)") }
    return "(first message of \(mailbox.reference) whose id is \(number))"
}

let mailTools = [
    Tool("mail_mailboxes", "List Mail accounts with their addresses and mailboxes (message and unread counts).") { _ in
        let all = try mailboxes()
        return try accounts().sorted { $0.value.name < $1.value.name }.compactMap { id, account in
            let own = all.filter { $0.account == id && $0.total > 0 }
            return own.isEmpty ? nil : object([
                "account": account.name,
                "addresses": account.addresses,
                "mailboxes": own.map { object(["name": $0.name, "messages": $0.total, "unread": $0.unread > 0 ? $0.unread : nil]) },
            ])
        }
    },

    Tool("mail_search", "Find emails, newest first. Every word of the query must appear in the subject, sender or preview. With no query it lists the latest mail. Use mail_read for the full body.", .read, [
        p("query", "Words to look for, e.g. \"invoice acme\""),
        p("unread_only", "Only unread messages", "boolean"),
        p("since", "Only messages received on or after this date"),
        p("mailbox", "inbox (default, all accounts), all (every mailbox), or a mailbox name from mail_mailboxes"),
        p("account", "Only this account: its name or one of its addresses"),
        p("limit", "Maximum messages; default 20", "integer"),
    ]) { args in
        let names = (try? accounts()) ?? [:]
        let wanted = (args.str("mailbox") ?? "inbox").lowercased(), account = (args.str("account") ?? "").lowercased()
        var scope = try mailboxes()
        if wanted == "inbox" {
            scope = scope.filter(\.isInbox)
        } else if wanted != "all" && !wanted.isEmpty {
            scope = scope.filter { $0.name.lowercased() == wanted || $0.name.lowercased().hasSuffix("/" + wanted) }
        }
        if !account.isEmpty {
            scope = scope.filter { names[$0.account].map { $0.name.lowercased() == account || $0.addresses.contains { $0.lowercased() == account } } ?? false }
        }
        guard !scope.isEmpty else { throw Fail("No mailbox matches. See mail_mailboxes for the names.") }

        // Gmail keeps messages in All Mail and files them under other mailboxes as labels.
        let ids = scope.map { String($0.id) }.joined(separator: ",")
        var conditions = ["m.deleted = 0", "(m.mailbox IN (\(ids)) OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id IN (\(ids))))"]
        var values: [Any] = []
        for word in (args.str("query") ?? "").split(separator: " ") {
            conditions.append("(s.subject LIKE ? OR a.address LIKE ? OR a.comment LIKE ? OR p.summary LIKE ?)")
            values += Array(repeating: "%\(word)%", count: 4)
        }
        if args.bool("unread_only") == true { conditions.append("m.read = 0") }
        if let since = try args.date("since") {
            conditions.append("m.date_received >= ?")
            values.append(Int(since.date.timeIntervalSince1970))
        }
        let limit = args.int("limit") ?? 20
        let found = try rows("""
            SELECT m.ROWID, m.subject_prefix, s.subject, a.comment, a.address, m.date_received, m.read, m.flagged, m.mailbox, m.message_id, p.summary
            FROM messages m
            JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN summaries p ON p.ROWID = m.summary
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY m.date_received DESC LIMIT \(limit * 4)
            """, values)

        let all = try mailboxes()
        var seen = Set<Int>()
        return found
            // The same message often sits in several mailboxes or accounts.
            .filter { row in (row[9] as? Int).map { $0 == 0 || seen.insert($0).inserted } ?? true }
            .prefix(limit)
            .map { row in
                let home = all.first { $0.id == row[8] as? Int }
                let sender = [row[3] as? String, (row[4] as? String).map { "<\($0)>" }].compactMap { $0 }.filter { !$0.isEmpty }
                return object([
                    "id": "\(row[0])",
                    "subject": "\(row[1] as? String ?? "")\(row[2] as? String ?? "")",
                    "from": sender.joined(separator: " "),
                    "date": Date(timeIntervalSince1970: TimeInterval(row[5] as? Int ?? 0)),
                    "unread": row[6] as? Int == 0 ? true : nil,
                    "flagged": row[7] as? Int == 1 ? true : nil,
                    "mailbox": home?.name,
                    "account": home.flatMap { names[$0.account]?.name },
                    "preview": (row[10] as? String).map { String($0.prefix(160)) },
                ])
            }
    },

    Tool("mail_read", "Read one email in full: headers, plain-text body and attachment names.", .read, [
        p("id", "Message id from mail_search", required: true),
        p("max_chars", "Truncate the body after this many characters; default 20000", "integer"),
    ]) { args in
        let r = try script("Mail", """
            set m to \(try message(args.req("id")))
            set attached to {}
            try
                set attached to name of mail attachments of m
            end try
            return {subject of m, sender of m, address of to recipients of m, address of cc recipients of m, date received of m, content of m, attached}
            """) as? [Any] ?? []
        guard r.count == 7 else { throw Fail("Couldn't read that message.") }
        return object([
            "subject": r[0], "from": r[1], "to": strings(r[2]), "cc": strings(r[3]), "date": r[4],
            "attachments": strings(r[6]),
            "body": clip(r[5] as? String ?? "", args.int("max_chars") ?? 20000),
        ])
    },

    Tool("mail_compose", "Write an email. By default it opens as a draft in Mail for the user to review; pass send=true only when the user has clearly asked to send it.", .write, [
        p("to", "Recipient addresses", "strings", required: true),
        p("subject", "Subject line", required: true),
        p("body", "Plain-text body", required: true),
        p("cc", "Cc addresses", "strings"),
        p("bcc", "Bcc addresses", "strings"),
        p("from", "Sender address, when the user has several; default is Mail's default account"),
        p("attachments", "Absolute paths of files to attach", "strings"),
        p("send", "Send immediately instead of leaving a draft open; default false", "boolean"),
    ]) { args in
        let to = args.list("to"), files = args.list("attachments"), send = args.bool("send") == true
        guard !to.isEmpty else { throw Fail("Missing required argument: to") }
        var lines = ["set m to make new outgoing message with properties {subject:\(q(try args.req("subject"))), content:\(q(try args.req("body"))), visible:true}"]
        if let from = args.str("from"), !from.isEmpty { lines.append("set sender of m to \(q(from))") }
        lines.append("tell m")
        for (kind, addresses) in [("to", to), ("cc", args.list("cc")), ("bcc", args.list("bcc"))] {
            for address in addresses {
                lines.append("make new \(kind) recipient at end of \(kind) recipients with properties {address:\(q(address))}")
            }
        }
        for path in files {
            guard FileManager.default.fileExists(atPath: path) else { throw Fail("No file at \(path)") }
            lines.append("tell content to make new attachment with properties {file name:(POSIX file \(q(path)))} at after last paragraph")
        }
        lines.append("end tell")
        // Mail needs a moment to load attachments before it can send them.
        if send { lines.append(files.isEmpty ? "send m" : "delay 2\nsend m") } else { lines.append("activate") }
        try script("Mail", lines.joined(separator: "\n"))
        return send ? "Sent to \(to.joined(separator: ", "))" : "Draft opened in Mail for review; not sent."
    },

    Tool("mail_mark", "Mark an email read/unread, flag it, or move it to the trash.", .destructive, [
        p("id", "Message id from mail_search", required: true),
        p("read", "true = read, false = unread", "boolean"),
        p("flagged", "Set or clear the flag", "boolean"),
        p("trash", "Move the message to the trash", "boolean"),
    ]) { args in
        var lines = ["set m to \(try message(args.req("id")))"]
        if let read = args.bool("read") { lines.append("set read status of m to \(read)") }
        if let flagged = args.bool("flagged") { lines.append("set flagged status of m to \(flagged)") }
        if args.bool("trash") == true { lines.append("delete m") }
        guard lines.count > 1 else { throw Fail("Pass read, flagged or trash.") }
        try script("Mail", lines.joined(separator: "\n"))
        return "Done"
    },
]
