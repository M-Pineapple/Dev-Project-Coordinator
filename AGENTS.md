# Dev Project Coordinator

Swift MCP server for a local project desk (coding and non-coding). Local JSON
knowledge base. Complements a memory/RAG product (live state vs why). No money-path
boundary. Public Apache-2.0 under M-Pineapple. Formerly Claude Project Coordinator.

## Governance

Follow the maintainer's internal engineering SOP. Closest-file-wins: this file
wins for repo-specific rules.

Memory namespace for this repo: `dev-cpc` (never use reserved trading tags; see the
maintainer's internal memory-tagging rules).

## Hard boundaries

- None money-path. Still treat user project data under `KnowledgeBase/projects/`
  and `KnowledgeBase/analytics/` as private — never commit those JSON files.
- Stdio MCP: never write diagnostics to stdout. Use `CPCLog` (stderr only).

## Coding standards

Swift 6. Use modern-swift / swift-testing skills from the Cursor skill set.
Prefer the official `MCP` Swift SDK over hand-rolled JSON-RPC.

## Build and test

```bash
swift build -c release
swift test
```

Executable: `.build/release/project-coordinator` (alias `.build/release/dpc`)

Optional: `DPC_KNOWLEDGE_BASE=/path/to/KnowledgeBase` overrides data location.
`CPC_KNOWLEDGE_BASE` still works through v2.x. If both are set, DPC wins.

## Gotchas

- Allowed project roots are compiled into `SecurityValidator.allowedBasePaths`.
  Rebuild after changing them.
- Version string lives in `CPCVersion` (`Sources/ProjectCoordinator/Version.swift`).
  Keep `mcp.json`, CHANGELOG, and GitHub releases in sync with it.
- Analytics migration is file-existence gated. Do not call a bulk remigrate on
  every start.
