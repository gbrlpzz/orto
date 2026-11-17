import Contacts
import EventKit
import Foundation

// Calendar, Reminders and Contacts go through Apple's frameworks directly:
// fast, no app launch, and recurring events expand properly.

private var store = EKEventStore()

private func authorize(_ type: EKEntityType) throws {
    if EKEventStore.authorizationStatus(for: type) == .fullAccess { return }
    let granted: Bool = wait { done in
        if type == .event {
            store.requestFullAccessToEvents { ok, _ in done(ok) }
        } else {
            store.requestFullAccessToReminders { ok, _ in done(ok) }
        }
    }
    let app = type == .event ? "Calendars" : "Reminders"
    guard granted else { throw Fail("No access to \(app). Allow Orto in System Settings › Privacy & Security › \(app).") }
    store = EKEventStore() // a store created before the grant stays empty
}

private func calendar(_ name: String?, for type: EKEntityType) throws -> EKCalendar? {
    guard let name, !name.isEmpty else { return nil }
    // Names repeat across accounts, so "Account/Name" is accepted too, and writable calendars win ties.
    let all = store.calendars(for: type).sorted { $0.allowsContentModifications && !$1.allowsContentModifications }
    func named(_ wanted: String) -> (EKCalendar) -> Bool {
        { wanted.caseInsensitiveCompare($0.title) == .orderedSame }
    }
    guard let match = all.first(where: { "\($0.source?.title ?? "")/\($0.title)".caseInsensitiveCompare(name) == .orderedSame })
        ?? all.first(where: named(name)) else {
        throw Fail("No \(type == .event ? "calendar" : "reminder list") named \"\(name)\". Available: \(all.map(\.title).joined(separator: ", "))")
    }
    return match
}

private func recurrence(_ args: Args) throws -> [EKRecurrenceRule]? {
    guard let text = args.str("repeat") else { return nil }
    let frequencies: [String: EKRecurrenceFrequency] = ["daily": .daily, "weekly": .weekly, "monthly": .monthly, "yearly": .yearly]
    if text == "none" || text.isEmpty { return [] }
    guard let frequency = frequencies[text] else { throw Fail("repeat must be daily, weekly, monthly, yearly or none") }
    let end = try args.date("repeat_until").map { EKRecurrenceEnd(end: $0.date) }
    return [EKRecurrenceRule(recurrenceWith: frequency, interval: max(args.int("repeat_every") ?? 1, 1), end: end)]
}

private let repeatParams = [
    p("repeat", "daily, weekly, monthly, yearly, or none to stop repeating"),
    p("repeat_every", "Interval for repeat, e.g. 2 = every other week", "integer"),
    p("repeat_until", "Last date the repetition applies"),
]

// MARK: - Calendar

/// Occurrences of a recurring event share one identifier, so theirs carry the start time too.
private func eventID(_ event: EKEvent) -> String {
    let id = event.eventIdentifier ?? ""
    return event.hasRecurrenceRules || event.isDetached ? "\(id)@\(Int(event.startDate.timeIntervalSince1970))" : id
}

private func findEvent(_ id: String) throws -> EKEvent {
    if let at = id.lastIndex(of: "@"), let seconds = TimeInterval(id[id.index(after: at)...]) {
        let start = Date(timeIntervalSince1970: seconds), base = String(id[..<at])
        let window = store.predicateForEvents(withStart: start.addingTimeInterval(-86400), end: start.addingTimeInterval(86400), calendars: nil)
        if let event = store.events(matching: window).first(where: { $0.eventIdentifier == base && $0.startDate == start }) {
            return event
        }
    }
    guard let event = store.event(withIdentifier: id) else { throw Fail("No event with id \(id)") }
    return event
}

private func describe(_ event: EKEvent) -> [String: Any] {
    object([
        "id": eventID(event),
        "title": event.title,
        "start": event.isAllDay ? day(event.startDate) : stamp(event.startDate),
        "end": event.isAllDay ? day(event.endDate) : stamp(event.endDate),
        "all_day": event.isAllDay ? true : nil,
        "calendar": event.calendar?.title,
        "location": event.location,
        "notes": event.notes,
        "url": event.url?.absoluteString,
        "repeats": event.hasRecurrenceRules ? true : nil,
        "attendees": event.attendees?.compactMap { $0.name ?? $0.url.absoluteString },
    ])
}

private func apply(_ args: Args, to event: EKEvent) throws {
    if let title = args.str("title") { event.title = title }
    if let location = args.str("location") { event.location = location }
    if let notes = args.str("notes") { event.notes = notes }
    if let url = args.str("url") { event.url = URL(string: url) }
    if let calendar = try calendar(args.str("calendar"), for: .event) { event.calendar = calendar }

    let start = try args.date("start"), end = try args.date("end")
    let length = event.startDate.map { event.endDate.timeIntervalSince($0) }
    if let start {
        event.startDate = start.date
        if end == nil { event.endDate = start.date.addingTimeInterval(length ?? (start.timed ? 3600 : 0)) }
    }
    if let end { event.endDate = end.date }
    if let allDay = args.bool("all_day") ?? start.map({ !$0.timed }) { event.isAllDay = allDay }
    guard event.startDate != nil, event.endDate >= event.startDate else { throw Fail("An event needs a start, and an end that isn't before it.") }

    if let minutes = args.int("alert_minutes") {
        event.alarms = minutes < 0 ? nil : [EKAlarm(relativeOffset: TimeInterval(-60 * minutes))]
    }
    if let rules = try recurrence(args) { event.recurrenceRules = rules.isEmpty ? nil : rules }
}

private let eventParams = [
    p("location", "Place or address"),
    p("notes", "Notes"),
    p("url", "Link attached to the event"),
    p("calendar", "Calendar name, or Account/Name when several share a name; defaults to the Mac's default calendar"),
    p("all_day", "All-day event. Implied when start has no time.", "boolean"),
    p("alert_minutes", "Alert this many minutes before the start; -1 removes alerts", "integer"),
] + repeatParams

private let spanParam = p("all_future", "For a repeating event: also change every later occurrence instead of only this one", "boolean")

let calendarTools = [
    Tool("calendar_list", "List calendars and reminder lists, with which ones are writable.") { _ in
        try authorize(.event)
        try authorize(.reminder)
        func rows(_ type: EKEntityType, default chosen: EKCalendar?) -> [[String: Any]] {
            store.calendars(for: type).map {
                object(["name": $0.title, "account": $0.source?.title, "read_only": $0.allowsContentModifications ? nil : true,
                        "default": $0.calendarIdentifier == chosen?.calendarIdentifier ? true : nil])
            }
        }
        return ["calendars": rows(.event, default: store.defaultCalendarForNewEvents),
                "reminder_lists": rows(.reminder, default: store.defaultCalendarForNewReminders())]
    },

    Tool("calendar_events", "List calendar events in a date range (default: the next 7 days), optionally filtered by text or calendar. Repeating events are expanded into occurrences.", .read, [
        p("from", "Range start; default today"),
        p("to", "Range end; default from + days"),
        p("days", "Length of the range when to is omitted; default 7", "integer"),
        p("query", "Only events whose title, location or notes contain this text"),
        p("calendar", "Only this calendar"),
        p("limit", "Maximum events; default 50", "integer"),
    ]) { args in
        try authorize(.event)
        let from = try args.date("from")?.date ?? Calendar.current.startOfDay(for: Date())
        var to = from.addingTimeInterval(TimeInterval(86400 * (args.int("days") ?? 7)))
        if let end = try args.date("to") {
            // A bare end date means "through that day".
            to = end.timed ? end.date : end.date.addingTimeInterval(86400)
        }
        let calendars = try calendar(args.str("calendar"), for: .event).map { [$0] }
        var events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: calendars))
        if let query = args.str("query"), !query.isEmpty {
            events = events.filter { event in
                [event.title, event.location, event.notes].contains { $0?.localizedCaseInsensitiveContains(query) == true }
            }
        }
        // The same calendar subscribed from two accounts yields every event twice.
        var seen = Set<String>()
        events = events.filter { seen.insert("\($0.title ?? "")|\($0.startDate!)|\($0.endDate!)").inserted }
        return events.sorted { $0.startDate < $1.startDate }.prefix(args.int("limit") ?? 50).map { event in
            var row = describe(event)
            if let notes = row["notes"] as? String { row["notes"] = clip(notes, 300) }
            return row
        }
    },

    Tool("calendar_create", "Create a calendar event.", .write, [
        p("title", "Event title", required: true),
        p("start", "Start, e.g. 2026-03-09T14:30, or 2026-03-09 for all-day", required: true),
        p("end", "End; default one hour after start"),
    ] + eventParams) { args in
        try authorize(.event)
        _ = try (args.req("title"), args.req("start"))
        let event = EKEvent(eventStore: store)
        event.calendar = store.defaultCalendarForNewEvents
        try apply(args, to: event)
        try store.save(event, span: .thisEvent, commit: true)
        return describe(event)
    },

    Tool("calendar_update", "Change an event. Only the fields you pass are changed.", .write, [
        p("id", "Event id from calendar_events", required: true),
        p("title", "New title"),
        p("start", "New start; the duration is kept unless end is given"),
        p("end", "New end"),
        spanParam,
    ] + eventParams) { args in
        try authorize(.event)
        let event = try findEvent(args.req("id"))
        try apply(args, to: event)
        try store.save(event, span: args.bool("all_future") == true ? .futureEvents : .thisEvent, commit: true)
        return describe(event)
    },

    Tool("calendar_delete", "Delete an event.", .destructive, [
        p("id", "Event id from calendar_events", required: true),
        spanParam,
    ]) { args in
        try authorize(.event)
        let event = try findEvent(args.req("id"))
        let title = event.title ?? ""
        try store.remove(event, span: args.bool("all_future") == true ? .futureEvents : .thisEvent, commit: true)
        return "Deleted \"\(title)\""
    },
]

// MARK: - Reminders

private let priorities = ["none": 0, "high": 1, "medium": 5, "low": 9]

private func findReminder(_ id: String) throws -> EKReminder {
    guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw Fail("No reminder with id \(id)") }
    return reminder
}

private func dueDate(_ reminder: EKReminder) -> Date? {
    reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
}

private func describe(_ reminder: EKReminder) -> [String: Any] {
    let due = dueDate(reminder)
    return object([
        "id": reminder.calendarItemIdentifier,
        "title": reminder.title,
        "list": reminder.calendar?.title,
        "due": due.map { reminder.dueDateComponents?.hour == nil ? day($0) : stamp($0) },
        "completed": reminder.isCompleted ? true : nil,
        "priority": priorities.first { $0.value == reminder.priority && $0.value != 0 }?.key,
        "notes": reminder.notes,
        "repeats": reminder.hasRecurrenceRules ? true : nil,
    ])
}

private func apply(_ args: Args, to reminder: EKReminder) throws {
    if let title = args.str("title") { reminder.title = title }
    if let notes = args.str("notes") { reminder.notes = notes }
    if let list = try calendar(args.str("list"), for: .reminder) { reminder.calendar = list }
    if let completed = args.bool("completed") { reminder.isCompleted = completed }
    if let name = args.str("priority") {
        guard let priority = priorities[name] else { throw Fail("priority must be none, low, medium or high") }
        reminder.priority = priority
    }
    if args.has("due") {
        reminder.alarms?.forEach(reminder.removeAlarm)
        if let due = try args.date("due") {
            let parts: Set<Calendar.Component> = due.timed ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: due.date)
            if due.timed { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
        } else {
            reminder.dueDateComponents = nil
        }
    }
    if let rules = try recurrence(args) {
        guard rules.isEmpty || reminder.dueDateComponents != nil else { throw Fail("A repeating reminder needs a due date.") }
        reminder.recurrenceRules = rules.isEmpty ? nil : rules
    }
}

private let reminderParams = [
    p("notes", "Notes"),
    p("due", "Due date (2026-03-09) or date and time (2026-03-09T09:00, which also alerts). Empty string clears it."),
    p("priority", "none, low, medium or high"),
    p("list", "Reminder list name; defaults to the Mac's default list"),
] + repeatParams

let reminderTools = [
    Tool("reminders_list", "List reminders: open ones by default, soonest due first.", .read, [
        p("list", "Only this reminder list"),
        p("completed", "List completed reminders instead of open ones", "boolean"),
        p("due_before", "Only open reminders due before this date (includes overdue)"),
        p("query", "Only reminders whose title or notes contain this text"),
        p("limit", "Maximum reminders; default 100", "integer"),
    ]) { args in
        try authorize(.reminder)
        let lists = try calendar(args.str("list"), for: .reminder).map { [$0] }
        let predicate = args.bool("completed") == true
            ? store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: lists)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: try args.date("due_before")?.date, calendars: lists)
        var reminders: [EKReminder] = wait { done in store.fetchReminders(matching: predicate) { done($0 ?? []) } }
        if let query = args.str("query"), !query.isEmpty {
            reminders = reminders.filter { reminder in
                [reminder.title, reminder.notes].contains { $0?.localizedCaseInsensitiveContains(query) == true }
            }
        }
        if args.bool("completed") == true {
            reminders.sort { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
        } else {
            reminders.sort { (dueDate($0) ?? .distantFuture) < (dueDate($1) ?? .distantFuture) }
        }
        return reminders.prefix(args.int("limit") ?? 100).map(describe)
    },

    Tool("reminders_create", "Create a reminder.", .write, [p("title", "What to be reminded of", required: true)] + reminderParams) { args in
        try authorize(.reminder)
        _ = try args.req("title")
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = store.defaultCalendarForNewReminders()
        try apply(args, to: reminder)
        try store.save(reminder, commit: true)
        return describe(reminder)
    },

    Tool("reminders_update", "Change a reminder or mark it completed. Only the fields you pass are changed.", .write, [
        p("id", "Reminder id from reminders_list", required: true),
        p("title", "New title"),
        p("completed", "true to complete, false to reopen", "boolean"),
    ] + reminderParams) { args in
        try authorize(.reminder)
        let reminder = try findReminder(args.req("id"))
        try apply(args, to: reminder)
        try store.save(reminder, commit: true)
        return describe(reminder)
    },

    Tool("reminders_delete", "Delete a reminder.", .destructive, [p("id", "Reminder id from reminders_list", required: true)]) { args in
        try authorize(.reminder)
        let reminder = try findReminder(args.req("id"))
        let title = reminder.title ?? ""
        try store.remove(reminder, commit: true)
        return "Deleted \"\(title)\""
    },
]

// MARK: - Contacts

let contactTools = [
    Tool("contacts_search", "Look up people in Contacts by name, or by email address, to get their emails and phone numbers.", .read, [
        p("query", "Name (or part of it), or a full email address", required: true),
        p("limit", "Maximum contacts; default 20", "integer"),
    ]) { args in
        let query = try args.req("query"), contacts = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) != .authorized {
            let granted: Bool = wait { done in contacts.requestAccess(for: .contacts) { ok, _ in done(ok) } }
            guard granted else { throw Fail("No access to Contacts. Allow Orto in System Settings › Privacy & Security › Contacts.") }
        }
        let keys = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor, CNContactJobTitleKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let predicate = query.contains("@")
            ? CNContact.predicateForContacts(matchingEmailAddress: query)
            : CNContact.predicateForContacts(matchingName: query)
        return try contacts.unifiedContacts(matching: predicate, keysToFetch: keys).prefix(args.int("limit") ?? 20).map { contact in
            object([
                "name": CNContactFormatter.string(from: contact, style: .fullName),
                "organization": contact.organizationName,
                "job_title": contact.jobTitle,
                "emails": contact.emailAddresses.map { $0.value as String },
                "phones": contact.phoneNumbers.map(\.value.stringValue),
            ])
        }
    },
]
