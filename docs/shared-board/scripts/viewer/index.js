// dpc-board-viewer: read-only MCP (Streamable HTTP, stateless JSON-RPC) over the DPC board in GitHub.
const PROTOCOL = "2025-06-18";
const SERVER = { name: "dpc-board-viewer", version: "1.0.0" };
const TTL_MS = 60_000;
const STALE_MS = 14 * 86_400_000;
const cache = new Map(); // isolate-level cache; Cache API is a no-op on workers.dev

const TOOLS = [
  { name: "list_projects", description: "List every DPC project with status, kind, last modified and card counts per column. Read-only.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false }, annotations: { readOnlyHint: true } },
  { name: "get_project", description: "One project's details and its board cards grouped by column. Read-only.",
    inputSchema: { type: "object", properties: { name: { type: "string", description: "Exact project name (case-insensitive)" } }, required: ["name"], additionalProperties: false },
    annotations: { readOnlyHint: true } },
  { name: "board_summary", description: "Board totals: projects, stale, blocked (parked), done, and card counts per column, as the DPC desk line. Read-only.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false }, annotations: { readOnlyHint: true } },
];

async function sha(s) { return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))); }
async function authorised(req, token, pathKey) {
  const h = req.headers.get("Authorization") || "";
  const given = pathKey || (h.startsWith("Bearer ") ? h.slice(7) : "");
  const [a, b] = await Promise.all([sha(given), sha(token)]);
  return crypto.subtle.timingSafeEqual(a, b) && given.length > 0;
}

async function gh(env, path, raw) {
  const key = path + (raw ? "#raw" : "");
  const hit = cache.get(key);
  if (hit && Date.now() - hit.t < TTL_MS) return hit.v;
  const url = `${env.GITHUB_API}/repos/${env.GITHUB_REPO}/contents/${path.split("/").map(encodeURIComponent).join("/")}?ref=${env.GITHUB_REF}`;
  const r = await fetch(url, { headers: {
    Authorization: `Bearer ${env.GITHUB_TOKEN}`, "User-Agent": "dpc-board-viewer",
    Accept: raw ? "application/vnd.github.raw+json" : "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" } });
  if (!r.ok) throw new Error(`GitHub ${r.status} for ${path}`);
  const v = await r.json();
  cache.set(key, { t: Date.now(), v });
  return v;
}

async function loadBoard(env) {
  const [listing, board] = await Promise.all([gh(env, "projects", false), gh(env, "desk/cards.json", true)]);
  const files = listing.filter(f => f.type === "file" && f.name.endsWith(".json") && !f.name.endsWith("-analytics.json"));
  const projects = await Promise.all(files.map(f => gh(env, `projects/${f.name}`, true)));
  return { projects, board: { columns: board.columns || [], cards: board.cards || [] } };
}

function counts(columns, cards) { const c = Object.fromEntries(columns.map(k => [k, 0])); for (const x of cards) c[x.column] = (c[x.column] || 0) + 1; return c; }

function staleNames(projects, cards, now) {
  return projects.filter(p => {
    const times = [Date.parse(p.lastModified) || 0, ...cards.filter(c => c.project === p.name).map(c => Date.parse(c.updated) || 0)];
    return now - Math.max(...times) > STALE_MS;
  }).map(p => p.name);
}

async function callTool(env, name, args) {
  const { projects, board } = await loadBoard(env);
  const sorted = [...projects].sort((a, b) => a.name < b.name ? -1 : 1);
  if (name === "list_projects") {
    return sorted.map(p => ({ name: p.name, status: p.status, kind: p.kind, lastModified: p.lastModified,
      cards: counts(board.columns, board.cards.filter(c => c.project === p.name)) }));
  }
  if (name === "get_project") {
    const want = String(args?.name || "").toLowerCase();
    const p = projects.find(x => x.name.toLowerCase() === want);
    if (!p) throw new Error(`No project named "${args?.name}"`);
    const mine = board.cards.filter(c => c.project === p.name).sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
    const byColumn = Object.fromEntries(board.columns.map(k => [k, []]));
    for (const c of mine) (byColumn[c.column] ||= []).push({ id: c.id, title: c.title, updated: c.updated, ...(c.memoryRef ? { memoryRef: c.memoryRef } : {}) });
    const { name: n, status, kind, description, lastModified, techStack, currentTasks } = p;
    return { name: n, status, kind, description, lastModified, techStack, currentTasks, cards: byColumn };
  }
  if (name === "board_summary") {
    const c = counts(board.columns, board.cards);
    const stale = staleNames(projects, board.cards, Date.now());
    const blocked = board.cards.filter(x => x.column.toLowerCase() === "parked").length;
    const done = board.cards.filter(x => x.column.toLowerCase() === "done").length;
    const line = `DPC desk  projects=${projects.length}  stale=${stale.length}  blocked=${blocked}  done=${done}\ncols: ${board.columns.map(k => `${k}=${c[k] || 0}`).join(" ")}`;
    return { line, projects: projects.length, stale: stale.length, staleProjects: stale, blocked, done, totalCards: board.cards.length, columns: c };
  }
  throw new Error(`Unknown tool ${name}`);
}

const rpc = (id, result) => ({ jsonrpc: "2.0", id, result });
const rpcErr = (id, code, message) => ({ jsonrpc: "2.0", id, error: { code, message } });

async function handle(env, msg) {
  const { id, method, params } = msg || {};
  if (id === undefined || id === null) return null; // notification
  switch (method) {
    case "initialize":
      return rpc(id, { protocolVersion: params?.protocolVersion || PROTOCOL, capabilities: { tools: { listChanged: false } }, serverInfo: SERVER,
        instructions: "Read-only view of the DPC board. Tools: board_summary, list_projects, get_project." });
    case "ping": return rpc(id, {});
    case "tools/list": return rpc(id, { tools: TOOLS });
    case "tools/call":
      try {
        const out = await callTool(env, params?.name, params?.arguments);
        return rpc(id, { content: [{ type: "text", text: JSON.stringify(out, null, 1) }], structuredContent: Array.isArray(out) ? { projects: out } : out });
      } catch (e) {
        if (String(e.message).startsWith("Unknown tool")) return rpcErr(id, -32602, e.message);
        return rpc(id, { content: [{ type: "text", text: `Error: ${e.message}` }], isError: true });
      }
    default: return rpcErr(id, -32601, `Method not found: ${method}`);
  }
}

const json = (body, status = 200, extra = {}) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...extra } });

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (url.pathname === "/") return new Response("dpc-board-viewer: read-only MCP at /mcp/<key> (or /mcp with a Bearer header)\n");
    const m = url.pathname.match(/^\/mcp(?:\/([A-Za-z0-9_-]{16,128}))?\/?$/);
    if (!m) return json({ error: "not found" }, 404);
    const pathKey = m[1] || "";
    if (!env.GITHUB_TOKEN || !env.VIEWER_KEY) return json({ error: "not configured", detail: "GITHUB_TOKEN and VIEWER_KEY secrets are not set" }, 503);
    if (!(await authorised(req, env.VIEWER_KEY, pathKey))) return json({ error: "unauthorised" }, pathKey ? 403 : 401);
    if (req.method === "GET") return new Response("SSE stream not offered", { status: 405, headers: { Allow: "POST, DELETE" } });
    if (req.method === "DELETE") return new Response(null, { status: 204 });
    if (req.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
    let body;
    try { body = await req.json(); } catch { return json(rpcErr(null, -32700, "Parse error"), 400); }
    if (Array.isArray(body)) {
      const out = (await Promise.all(body.map(m => handle(env, m)))).filter(Boolean);
      return out.length ? json(out) : new Response(null, { status: 202 });
    }
    const out = await handle(env, body);
    return out ? json(out) : new Response(null, { status: 202 });
  },
};
