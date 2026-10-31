#!/usr/bin/python3
"""Two-way sync of ~/DPC-mirror with the private board repo (the host board is the source of truth).

Only desk/cards.json (the Dock board) is sent back. Local edits to any other tracked
file are discarded, as before, because long-running Mac servers hold stale project data.
cards.json is normalised against HEAD first (union by card id, newest "updated" wins),
so a stale in-memory board can never revert or drop a card. Conflicts in a rebase go
through the dpccards merge driver with the same rule.
"""
import fcntl, os, shutil, subprocess, sys, time

M = os.path.expanduser("~/DPC-mirror")
MERGE = os.path.expanduser("~/.local/bin/dpc-cards-merge.py")
CARDS = "desk/cards.json"
SAVE = os.path.expanduser("~/Library/Logs/dpc-conflicts")

def g(*a, check=False, out=False):
    r = subprocess.run(["git", "-C", M] + list(a), capture_output=True, text=True, timeout=120)
    if check and r.returncode != 0:
        raise RuntimeError("git %s: %s" % (a[0], r.stderr.strip()[:200]))
    return r.stdout if out else r.returncode

def log(msg):
    print("%s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg), flush=True)

def normalise_and_commit():
    changed = [f for f in g("diff", "-z", "--name-only", "HEAD", out=True).split("\0") if f]
    others = [f for f in changed if f != CARDS]
    if others:
        g("checkout", "HEAD", "--", *others)
    if CARDS not in changed:
        return False
    base = os.path.join(M, ".git", "dpc-head-cards.json")
    with open(base, "w") as f:
        f.write(g("show", "HEAD:" + CARDS, out=True))
    subprocess.run(["/usr/bin/python3", MERGE, "--pair", base, os.path.join(M, CARDS)], check=True, timeout=60)
    if g("diff", "--quiet", "HEAD", "--", CARDS) == 0:
        return False
    g("add", CARDS, check=True)
    g("commit", "-q", "-m", "Dock edit (Mac)", check=True)
    return True

def integrate():
    if g("merge-base", "--is-ancestor", "origin/main", "HEAD") == 0:
        return
    if g("merge-base", "--is-ancestor", "HEAD", "origin/main") == 0:
        g("merge", "-q", "--ff-only", "origin/main", check=True)
        return
    r = subprocess.run(["git", "-C", M, "rebase", "-q", "origin/main"], capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        log("rebase said: " + (r.stderr or r.stdout).strip().replace("\n", " | ")[:300])
        g("rebase", "--abort")
        os.makedirs(SAVE, exist_ok=True)
        keep = os.path.join(SAVE, time.strftime("%Y%m%d-%H%M%S") + "-cards.json")
        with open(keep, "w") as f:
            f.write(g("show", "HEAD:" + CARDS, out=True))
        g("reset", "-q", "--hard", "origin/main", check=True)
        subprocess.run(["/usr/bin/python3", MERGE, "--pair", keep, os.path.join(M, CARDS)], check=True, timeout=60)
        # merge --pair keeps the file's newer cards; now fold in the saved local ones
        tmp = os.path.join(M, ".git", "dpc-up.json")
        shutil.copy(os.path.join(M, CARDS), tmp)
        shutil.copy(keep, os.path.join(M, CARDS))
        subprocess.run(["/usr/bin/python3", MERGE, "--pair", tmp, os.path.join(M, CARDS)], check=True, timeout=60)
        if g("diff", "--quiet", "HEAD", "--", CARDS) != 0:
            g("add", CARDS, check=True)
            g("commit", "-q", "-m", "Dock edit (Mac, merged after rebase failure)", check=True)
        log("rebase failed; merged by card instead, local copy saved at " + keep)

def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--debounce":
        time.sleep(3)
    os.chdir(M)
    with open(os.path.join(M, ".dpc-sync.lock"), "a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:
            if os.path.isdir(os.path.join(M, ".git", "rebase-merge")) or os.path.isdir(os.path.join(M, ".git", "rebase-apply")):
                g("rebase", "--abort")
            made = normalise_and_commit()
            pushed = False
            for _ in range(3):
                made = normalise_and_commit() or made
                g("fetch", "-q", "origin", "main", check=True)
                made = normalise_and_commit() or made
                integrate()
                if g("merge-base", "--is-ancestor", "HEAD", "origin/main") == 0:
                    break
                if g("push", "-q", "origin", "HEAD:main") == 0:
                    pushed = True
                    g("fetch", "-q", "origin", "main")
                    break
                time.sleep(2)
            ahead = g("rev-list", "--count", "origin/main..HEAD", out=True).strip()
            log("%s %scommitted=%s pushed=%s unpushed=%s" % (
                g("rev-parse", "--short", "HEAD", out=True).strip(), "", made, pushed, ahead))
        except Exception as e:
            log("error: %s" % e)
            return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
