---
name: orto
description: Read and change the user's Apple apps on this Mac through Orto — Calendar events, Reminders, Apple Mail (search, read, draft, send), Notes, Contacts, iMessage and Shortcuts. Use when a task involves the user's schedule, to-dos, email, notes, a person's email or phone number, sending a message, or running one of their shortcuts.
---

# Orto

Orto exposes the Mac's Apple apps as 22 tools. Reach them either way; both hit the same code:

- **MCP tools** named `calendar_events`, `mail_search`, … on the `orto` server (load them with tool search if they are deferred).
- **CLI**, when the MCP server isn't connected or you want to pipe output:
  `~/Applications/Orto.app/Contents/MacOS/orto call <tool> '<json arguments>'`.
  `orto tools` lists every tool with a one-line description.

## Tools

| App | Tools |
|---|---|
| Calendar | `calendar_list` `calendar_events` `calendar_create` `calendar_update` `calendar_delete` |
| Reminders | `reminders_list` `reminders_create` `reminders_update` `reminders_delete` |
| Mail | `mail_mailboxes` `mail_search` `mail_read` `mail_compose` `mail_mark` |
| Notes | `notes_search` `notes_read` `notes_create` `notes_update` |
| Contacts | `contacts_search` |
| Messages | `messages_send` |
| Shortcuts | `shortcuts_list` `shortcuts_run` |

## Conventions

- **Dates** are ISO 8601 in the Mac's local time zone: `2026-03-09T14:30`. A date with no time (`2026-03-09`) means all-day for events and "due that day, no alert" for reminders. Work out relative dates ("next Tuesday") yourself before calling.
- **Ids** come from the list/search tools; pass them back unchanged. An occurrence of a repeating event has its own id, and editing it gives it a new one — use the id the update returns.
- **Only passed fields change** on update tools. An empty `due` clears a reminder's due date.
- Results are JSON with empty fields left out.

## How to do common things

- **What's on my calendar**: `calendar_events` with `from`/`to` or `days`. It defaults to the next 7 days and 50 events; subscribed calendars can be noisy, so filter with `calendar` or `query`.
- **Add an event**: `calendar_create`. Several calendars can share a name across accounts; check `calendar_list` and pass `Account/Name` when it matters. Invitees can't be added — macOS doesn't allow it.
- **Change one occurrence vs. the series**: `all_future: true` on update/delete applies from that occurrence onward.
- **Find an email**: `mail_search` searches the inbox of every account by default; each word of `query` must match the subject, sender or preview. Use `mailbox: "all"` to include archives, sent mail and spam, then `mail_read` with the id for the body.
- **Write an email**: `mail_compose` opens a draft in Mail for the user to review. Pass `send: true` only when the user has said to send it. Look addresses up with `contacts_search` rather than guessing.
- **Notes**: `notes_search` matches titles and bodies. Prefer `notes_update` with `append`; replacing `body` drops images and attachments in the note.
- **Anything else on the Mac**: check `shortcuts_list` — the user may have a shortcut for it.

## Care

`mail_compose` with `send`, `messages_send`, the delete tools, `mail_mark` with `trash`, and `shortcuts_run` act on the user's real data or reach other people. Confirm the details with the user first unless they already asked for exactly that.

## When it fails

Errors say what to do. The usual one is a missing macOS permission: the user grants it in System Settings › Privacy & Security (Calendars, Reminders, Contacts, Automation, and Full Disk Access for reading mail), listed under Orto. Rebuilding Orto resets these grants.
