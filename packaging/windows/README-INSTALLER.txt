Bosca Ceoil Blue MCP - Windows x64 Preview

1. Run the Setup executable. Installation is per-user and does not require an
   administrator account. Node.js and MCP runtime dependencies are included.
2. Leave "Connect MCP to Codex" selected for quick setup. Optionally select
   "Allow Codex to edit songs and export files"; otherwise tools are read-only.
3. Start Bosca. In Codex Settings > MCP servers, restart the servers (or restart
   Codex). Keep Bosca open while asking Codex to inspect or compose music.

You can connect later inside Bosca: Advanced > MCP Settings > Install in Codex.
If Codex CLI is unavailable, install/open Codex and retry. For other MCP hosts,
use "Copy MCP host configuration" from the same settings dialog.

Data locations
- Application: %LOCALAPPDATA%\Programs\Bosca Ceoil Blue MCP
- MCP configuration: %LOCALAPPDATA%\BoscaCeoilBlueMCP\mcp.json
- Default songs: Documents\Bosca Ceoil Blue

Do not share mcp.json: it contains a local connection credential. The installed
application loads it automatically when no environment/saved-path override exists.
Only local 127.0.0.1 connections are accepted. Use MCP Settings to disable access,
switch edit mode, rotate the token or choose another song directory.

Setup preserves existing songs, token and root settings on upgrades. If a different
server already uses the name bosca-ceoil, setup leaves it unchanged and reports it.
Uninstall removes only a matching registration created by Bosca; songs and personal
settings remain. If Codex is unavailable during uninstall, remove bosca-ceoil
manually in Codex Settings > MCP servers.

This is an unsigned development preview, not an official upstream release.
Windows may show publisher/reputation prompts. No background service, startup
task, telemetry or firewall rule is installed.

Source: local feat/windows-installer branch of boscaceoil-blue.
MCP protocol and limitations: docs/mcp/README.md and docs/mcp/protocol.md in this
installation. Third-party notices are in licenses/ and runtime dependencies.

Codex setup uses the official CLI interface:
https://learn.chatgpt.com/docs/extend/mcp
