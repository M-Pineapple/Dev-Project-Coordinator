# Shared board (optional)

By default DPC keeps its KnowledgeBase on one machine. This guide shows one way to share a single board between an always-on host (for example a Grok Bot's Linux computer, where several agents write to it) and your desktop, where the Dock app and your editor read it and you drag cards. It also covers an optional read-only remote viewer for assistants that can only reach the board over the internet.

Git is the transport. A private GitHub repo holds the board; every machine is a clone.

```
 agents on the host ──> dpc wrapper ──> host KB (git) ──push/pull──> private repo <──push/pull── desktop mirror <── Dock app
                                                                         │
                                                                         └──> read-only viewer Worker (optional)
```

Nothing here is required. A single-machine DPC needs none of it.

## What you need

- A private GitHub repo for the board, for example `<owner>/<board-repo>`. Keep it private: it holds your project list.
- On the host: Swift 6, git and Python 3.
- On the desktop: git, Python 3 and `gh` signed in (macOS steps shown; any OS with a scheduler works).
- Optional viewer: a Cloudflare account and Wrangler.

## 1. Build DPC on the Linux host

Build from `main`, which includes the Linux build fix from PR #23.

```bash
git clone https://github.com/M-Pineapple/Dev-Project-Coordinator.git
cd Dev-Project-Coordinator
swift build -c release
mkdir -p ~/dpc/bin && cp .build/release/project-coordinator ~/dpc/bin/
```

## 2. Put the board in git

```bash
mkdir -p ~/dpc/kb && cd ~/dpc/kb   # DPC creates its folders here on first use (DPC_KNOWLEDGE_BASE=~/dpc/kb)
git init -b main
```

Add a `.gitignore` that keeps secrets and generated files out:

```
.dpc.lock
.dpc-sync.*
security-config.json
desk/.write-token
desk/index.html
*.bak
*.tmp*
*token*
*.key
*.pem
.env*
```

Add `.gitattributes` so card conflicts go to the merge driver (step 5):

```
desk/cards.json merge=dpccards
```

Commit, add the private repo as `origin`, and push.

## 3. Host transport: HTTPS token or deploy key

- **Fine-grained token (works where outbound SSH is blocked).** Create a fine-grained personal access token with access to the board repo only and *Contents: read and write*. Expose it to the agents' environment as `DPC_BOARD_GITHUB_TOKEN`. The wrapper passes it to git through an inline credential helper, so it is never written to `.git/config` or printed.
- **Deploy key (where SSH works).** Generate a key on the host, add it to the repo as a deploy key with write access, and set `git config core.sshCommand "ssh -i ~/.ssh/<key> -o IdentitiesOnly=yes"` in the KB. With a deploy key you can drop the token logic from the wrapper.

## 4. The wrapper: one door for every agent

[`scripts/dpc`](scripts/dpc) runs one DPC tool call per invocation:

```bash
dpc tools
dpc move_card '{"id":"c123","column":"done"}'
dpc sync
```

- Every call holds an `flock` on `$KB/.dpc.lock`, so concurrent agents never interleave writes.
- Before each call it commits any local work and pulls `origin/main` (fast-forward, or rebase), at most every 15 seconds, so desktop edits reach the agents.
- After a write it commits and pushes in the background, rebasing and retrying up to three times. If the push still fails it leaves `$KB/.dpc-sync.pending` with the reason; `dpc sync` retries.

Install it on the agents' `PATH` and register the merge driver in the KB:

```bash
cp scripts/dpc scripts/dpc-cards-merge.py ~/dpc/bin/ && chmod +x ~/dpc/bin/*
git -C ~/dpc/kb config merge.dpccards.driver "python3 $HOME/dpc/bin/dpc-cards-merge.py %O %A %B"
```

Set `DPC_ROOT` if you used a folder other than `~/dpc`.

## 5. The card merge driver

[`scripts/dpc-cards-merge.py`](scripts/dpc-cards-merge.py) merges two versions of `desk/cards.json` without losing cards:

- every card from both sides is kept, matched by `id` (DPC has no delete tool);
- where both sides changed the same card, the newer `updated` time wins;
- the output matches DPC's own JSON formatting byte for byte, so files are not rewritten for nothing.

Done cards older than the archive window are hidden by DPC when it reads the file. That state is not stored, so this driver needs no new key, and opening the desk does not rewrite `cards.json` just because a card has aged.

Git uses it through `.gitattributes`. The desktop sync also runs it in `--pair` mode before each commit, as a guard against any process saving an older copy of the board. Project files are not merged this way; on the desktop they are read-only (step 6).

## 6. Desktop two-way mirror

Clone the board with a separate read-write deploy key, created and registered with `gh`:

```bash
ssh-keygen -t ed25519 -N "" -C "dpc board desktop" -f ~/.ssh/dpc_board_rw
gh repo deploy-key add ~/.ssh/dpc_board_rw.pub -R <owner>/<board-repo> --allow-write -t "desktop read-write"
GIT_SSH_COMMAND="ssh -i ~/.ssh/dpc_board_rw -o IdentitiesOnly=yes" git clone git@github.com:<owner>/<board-repo>.git ~/DPC-mirror
cd ~/DPC-mirror
git config core.sshCommand "ssh -i $HOME/.ssh/dpc_board_rw -o IdentitiesOnly=yes"
git config merge.dpccards.driver "/usr/bin/python3 $HOME/.local/bin/dpc-cards-merge.py %O %A %B"
```

Copy [`scripts/dpc-mirror-sync.py`](scripts/dpc-mirror-sync.py) and `dpc-cards-merge.py` to `~/.local/bin/`. Each run:

1. sends back only `desk/cards.json` (the Dock board) and resets any other tracked file to the last synced copy, because project data is owned by the host;
2. folds the last synced cards into the local file (newest card wins), then commits;
3. fetches, fast-forwards or rebases (conflicts go to the merge driver), and pushes, retrying up to three times;
4. if a rebase still fails, it rebuilds the card file from both sides and keeps the local copy in `~/Library/Logs/dpc-conflicts/`.

Schedule it with [`scripts/io.example.dpc-mirror.plist`](scripts/io.example.dpc-mirror.plist): replace `<home>` with your home folder, copy it to `~/Library/LaunchAgents/`, then:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.example.dpc-mirror.plist
```

It runs when anything in `~/DPC-mirror/desk` changes (after a short pause), every two minutes, and at login. Point the Dock app, Cursor and Grok Build at the mirror with `DPC_KNOWLEDGE_BASE=$HOME/DPC-mirror`.

Expect a desktop drag to reach the host within about half a minute, and a host change to reach the desktop within about two minutes.

**Limit:** only card moves and new cards travel from the desktop. Project edits made on the desktop are discarded at the next sync; make those through the host.

## 7. Optional: read-only remote viewer

Some assistants can reach an MCP server only over HTTPS, and their connector forms offer OAuth but no custom headers. [`scripts/viewer/index.js`](scripts/viewer/index.js) is a small Cloudflare Worker that serves three read-only tools (`board_summary`, `list_projects`, `get_project`) from the board repo's `main` branch. It cannot write anything.

1. Copy `scripts/viewer/wrangler.jsonc.example` to `wrangler.jsonc` next to `index.js` and set `GITHUB_REPO`.
2. Create a fine-grained token with *Contents: read-only* on the board repo only.
3. Make a viewer key: `openssl rand -hex 32`.
4. Deploy with `npx wrangler deploy`, then set both secrets from your own terminal: `npx wrangler secret put GITHUB_TOKEN` and `npx wrangler secret put VIEWER_KEY`.
5. In the assistant, add a remote MCP connector with the URL `https://dpc-board-viewer.<your-subdomain>.workers.dev/mcp/<viewer key>`, Streamable HTTP, and leave every OAuth field empty. Clients that support headers can use `/mcp` with `Authorization: Bearer <viewer key>` instead.

Treat the full URL like a password: anyone who has it can read the board. To revoke access, set a new `VIEWER_KEY`.

## Rollback

- Desktop: `launchctl bootout gui/$(id -u)/io.example.dpc-mirror`, then remove the read-write deploy key from the repo settings.
- Host: run DPC directly against the KB without the wrapper; the KB is a normal folder.
- Viewer: delete the Worker or rotate `VIEWER_KEY`.
