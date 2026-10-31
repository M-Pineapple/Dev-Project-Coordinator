# DPC desk skill

Use with the Dev Project Coordinator MCP. Enable on a specialised Grok Bot or paste beside the prompt for Claude and Cursor.

## When to call which tool

| Situation | Tool |
|---|---|
| Start of a turn | `get_desk_summary` |
| Deep dive the user asked for | `list_projects` or `get_project_status` |
| Agent is in a git repo | `register_from_workspace` |
| Non-coding work from context | `file_under_project` |
| Wrong name | `rename_project` or `merge_projects` |
| New work item | `add_card` |
| Column change | `move_card` |
| Decision lives in memory | `update_card` with `memoryRef` only |
| User wants the page | `open_desk` |
| User asked for drag-and-drop or Add to Dock | `start_desk_server`. Give the one-time sign-in URL (valid once, for 10 minutes), then the plain URL for Dock. Calling the tool again mints a new code without rotating the write token. Do not call the write token one-time |

## 800-token rule

`get_desk_summary` is capped at 800 tokens (~3,200 characters). Do not pad it with notes. Do not call health, heatmap, and list together at session start.

## memoryRef convention

1. Write the why into the user's memory product.
2. Store an opaque id, hash, or tag on the card as `memoryRef`.
3. Never copy the memory text into DPC. DPC never calls a memory MCP.

## Page privacy

A Grok Bot Page of the desk stays private. Do not share it. The canonical view for other hosts is the local HTML file. Filters on a Page do not write JSON.
