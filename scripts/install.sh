#!/bin/sh
# Copies Orto.app to ~/Applications and registers it as an MCP server in Claude Desktop.
# With --remove, undoes both.
set -eu

APP="$HOME/Applications/Orto.app"
BIN="$APP/Contents/MacOS/orto"
CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

if [ "${1:-}" = "--remove" ]; then
	rm -rf "$APP"
else
	mkdir -p "$HOME/Applications"
	rm -rf "$APP"
	cp -R "$(dirname "$0")/../build/Orto.app" "$APP"
fi

if [ -d "$(dirname "$CONFIG")" ]; then
	[ -f "$CONFIG" ] && cp "$CONFIG" "$CONFIG.bak-orto"
	/usr/bin/python3 - "$CONFIG" "$BIN" "${1:-}" <<'EOF'
import json, os, sys
path, binary, flag = sys.argv[1:4]
config = json.load(open(path)) if os.path.exists(path) else {}
servers = config.setdefault("mcpServers", {})
if flag == "--remove":
    servers.pop("orto", None)
else:
    servers["orto"] = {"command": binary}
with open(path, "w") as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write("\n")
EOF
	echo "Claude Desktop config updated. Quit and reopen Claude to apply."
else
	echo "Claude Desktop not found; skipped its config."
fi

[ "${1:-}" = "--remove" ] || echo "Installed $BIN"
