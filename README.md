# Orto

Apple apps for Claude. A small local [MCP](https://modelcontextprotocol.io) server that lets Claude Desktop (or any MCP client) work with Calendar, Reminders, Mail, Notes, Contacts, Messages and Shortcuts on your Mac.

One Swift binary of about 350 KB, no dependencies, no background process, no network access. Everything stays on your machine.

## Install

Needs macOS 14 or later and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/gbrlpzz/orto && cd orto
make install
```

This builds `Orto.app`, copies it to `~/Applications`, and adds it to Claude Desktop's config. Quit and reopen Claude, and the tools are there.

For another MCP client, point it at the binary:

```json
{ "mcpServers": { "orto": { "command": "/Users/you/Applications/Orto.app/Contents/MacOS/orto" } } }
```

`make uninstall` removes the app and the config entry.

## Permissions

macOS asks once per app the first time Claude uses it: Calendars, Reminders, Contacts, and Automation for Mail, Notes and Messages. The prompts name Orto, and you can review them later in System Settings › Privacy & Security.

Reading mail additionally needs **Full Disk Access**, which macOS only lets you grant by hand: System Settings › Privacy & Security › Full Disk Access › add `~/Applications/Orto.app`. Orto opens that pane the first time it's needed. See [how it works](#how-it-works) for why.

Builds are ad-hoc signed, so macOS treats each rebuild as a new app and asks again. To keep permissions across rebuilds, sign with your own identity: `make install SIGN_ID="Apple Development: …"`.

## Tools

| | |
|---|---|
| **Calendar** | `calendar_list` · `calendar_events` · `calendar_create` · `calendar_update` · `calendar_delete` |
| **Reminders** | `reminders_list` · `reminders_create` · `reminders_update` · `reminders_delete` |
| **Mail** | `mail_mailboxes` · `mail_search` · `mail_read` · `mail_compose` · `mail_mark` |
| **Notes** | `notes_search` · `notes_read` · `notes_create` · `notes_update` |
| **Contacts** | `contacts_search` |
| **Messages** | `messages_send` |
| **Shortcuts** | `shortcuts_list` · `shortcuts_run` |

Shortcuts is the escape hatch: anything Orto doesn't cover, build a shortcut for it and Claude can run it.

`mail_compose` opens a draft for you to review unless Claude is explicitly told to send.

## From the terminal

The same tools work without Claude, which is handy for scripts and for checking permissions:

```sh
orto=~/Applications/Orto.app/Contents/MacOS/orto
$orto tools
$orto call calendar_events '{"days": 3}'
$orto call reminders_create '{"title": "Water the tomatoes", "due": "2026-06-01T18:00"}'
$orto call mail_search '{"query": "invoice", "unread_only": true}'
```

## How it works

- **Calendar, Reminders, Contacts** use EventKit and the Contacts framework directly, so they are fast and don't launch any app.
- **Notes, Messages** and writing mail use AppleScript, run in-process.
- **Searching mail** reads Mail's own index database, read-only. Mail's scripting interface takes tens of seconds to list a large inbox; the index answers in milliseconds. That file is protected, hence Full Disk Access.
- **Its own identity.** macOS attributes privacy prompts to whichever app launched a tool, and Claude Desktop doesn't declare calendar or contacts access, so a plain command-line server would be denied silently. Orto is a minimal app bundle that detaches from its parent's identity at launch, so the prompts and grants belong to Orto.

The whole thing is about a thousand lines in `Sources/orto`: `main.swift` is the MCP server, the other files are the tools.

## License

MIT. Not affiliated with Apple or Anthropic.
