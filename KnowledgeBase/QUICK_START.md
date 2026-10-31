# Quick start

## Build

```bash
git clone https://github.com/M-Pineapple/Claude-Project-Coordinator.git
cd Claude-Project-Coordinator
swift build -c release
```

The stdio binary is `.build/release/project-coordinator`. `.build/release/dpc` is the same server. There is no `--port` flag.

## Configure an MCP host

Use an absolute path. Example for Claude Desktop, Cursor, or Claude Code:

```json
{
  "mcpServers": {
    "project-coordinator": {
      "command": "/absolute/path/to/Claude-Project-Coordinator/.build/release/project-coordinator",
      "args": []
    }
  }
}
```

Optional env:

```text
DPC_KNOWLEDGE_BASE=/absolute/path/to/KnowledgeBase
```

`CPC_KNOWLEDGE_BASE` still works through v2.x. If both are set, DPC wins.

Restart the host.

## First prompts

```text
What is on my desk?
Register this workspace.
File the contract review under a legal project.
Open the desk page.
```

The agent should call `get_desk_summary` first. Open `KnowledgeBase/desk/index.html` from disk. Do not host that file.

## Allowed folders

Coding paths must sit under `~/Developer`, `~/Documents`, `~/GitHub`, `~/Projects`, `~/Desktop/Development`, or `~/Xcode`, or a root you add in `security-config.json` / `DPC_ALLOWED_PATHS`. Non-coding projects may have no path.
