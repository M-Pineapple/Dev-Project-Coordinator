#!/usr/bin/env python3
"""Merge two versions of DPC desk/cards.json without losing cards.

As a git merge driver:  dpc-cards-merge.py %O %A %B   (writes result into %A)
As a normaliser:        dpc-cards-merge.py --pair OLD NEW  (writes result into NEW)
Rule: union of cards by id; where both sides hold a card, the newer "updated"
wins (tie: the %A / NEW side). Columns: order of the winning side plus any extras.
Cards are never dropped (DPC has no delete tool).
"""
import json, os, sys, tempfile

def load(p):
    try:
        with open(p) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {"cards": [], "columns": []}
    except Exception:
        return None

def merge(a, b):
    """a = preferred on tie. Returns merged dict."""
    if a is None: return b
    if b is None: return a
    by = {}
    order = []
    for src in (a.get("cards", []), b.get("cards", [])):
        for c in src:
            cid = c.get("id")
            if cid not in by:
                by[cid] = c; order.append(cid)
            elif (c.get("updated") or "") > (by[cid].get("updated") or ""):
                by[cid] = c
    cols = list(a.get("columns", []))
    for c in b.get("columns", []):
        if c not in cols: cols.append(c)
    out = dict(b); out.update(a)
    out["cards"] = [by[i] for i in order]
    out["columns"] = cols
    return out

def dump(d, path):
    s = json.dumps(d, indent=2, sort_keys=True, ensure_ascii=False).replace('": ', '" : ').replace('/', '\\/')
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)), prefix=".cards.tmp-")
    with os.fdopen(fd, "w") as f:
        f.write(s)
    os.replace(tmp, path)

def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--pair":
        old, new = load(sys.argv[2]), load(sys.argv[3])
        if new is None: return 1
        m = merge(new, old)
        if m != new: dump(m, sys.argv[3])
        return 0
    if len(sys.argv) == 4:
        a, b = load(sys.argv[2]), load(sys.argv[3])
        if a is None and b is None: return 1
        dump(merge(a, b), sys.argv[2])
        return 0
    print(__doc__); return 2

if __name__ == "__main__":
    sys.exit(main())
