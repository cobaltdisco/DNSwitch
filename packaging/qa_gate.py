"""QA gate for packaging/release.sh (docs/12 §7).

  qa_gate.py gate <repo> <version> <max-age-hours> <expected.json>
      Prints the tested App's path and writes its per-architecture cdhashes
      to <expected.json>; on failure prints the reasons and exits 1.
  qa_gate.py check <app> <expected.json>
      Exits non-zero unless <app> carries exactly those cdhashes.

This guards against mistakes (no QA, a stale or partial run, a changed or
rebuilt bundle), not against someone deliberately editing the report: whoever
can do that can also edit release.sh.
"""
import datetime
import json
import os
import re
import subprocess
import sys

ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}  # no redirected index/dir


def run(*cmd):
    p = subprocess.run(cmd, capture_output=True, text=True, env=ENV)
    return p.returncode, p.stdout.strip(), p.stderr


def cdhash(path, arch):
    rc, _, err = run("/usr/bin/codesign", "-dvvv", "-a", arch, path)
    m = re.search(r"^CDHash=([0-9a-f]{40})$", err, re.M)
    if rc != 0 or not m:
        raise RuntimeError("cannot read the %s cdhash of %s" % (arch, path))
    return m.group(1)


def check(app, expected):
    """Exit non-zero unless both binaries, both architectures, match `expected`."""
    want = json.load(open(expected))
    for part, p in (("app", app), ("engine", os.path.join(app, "Contents", "MacOS", "dnswitch-engine"))):
        for arch, h in want[part].items():
            try:
                if cdhash(p, arch) != h:
                    sys.exit("%s %s cdhash is not the tested one" % (part, arch))
            except RuntimeError as e:
                sys.exit(str(e))


def gate(repo, version, max_age, expected_out):
    bad = []

    def git(*args, cwd=repo):
        rc, out, err = run("/usr/bin/git", "-C", cwd, *args)
        if rc != 0:
            raise RuntimeError("git %s failed in %s" % (" ".join(args), cwd))
        return out

    def no_links(*paths):
        for p in paths:
            if os.path.islink(p):
                bad.append("symlink not allowed: " + os.path.relpath(p, repo))

    def need(obj, key, typ, where="report"):
        v = obj.get(key) if isinstance(obj, dict) else None
        if not isinstance(v, typ):
            bad.append("%s field %r missing or not %s" % (where, key, typ.__name__))
            return None
        return v
    try:
        qa = os.path.join(repo, "dist", "qa")
        no_links(os.path.join(repo, "dist"), qa, os.path.join(qa, "rc"))
        pat = re.compile(re.escape(version) + r"-(\d{8})-(\d{6})$")
        runs = sorted((m.group(1) + m.group(2), d) for d in os.listdir(qa) if (m := pat.match(d)) and os.path.isdir(os.path.join(qa, d)))
        if not runs:
            print("no QA run for version %s in dist/qa/" % version)
            return 1
        run_dir = os.path.join(qa, runs[-1][1])  # newest by the run's own timestamp, never by mtime
        path = os.path.join(run_dir, "result.json")
        no_links(run_dir, path)
        with open(path, encoding="utf-8") as f:
            r = json.load(f)
        print("report: " + os.path.relpath(path, repo), file=sys.stderr)

        if need(r, "profile", str) not in ("release", "full"):
            bad.append("QA profile is %r, not release or full" % r.get("profile"))
        if need(r, "partial", bool) is not False or need(r, "dev", bool) is not False:
            bad.append("QA run was partial (--only) or a dev run (--dev)")
        if need(r, "verdict", str) != "GO":
            bad.append("QA verdict is %s: %s" % (r.get("verdict"), "; ".join(r.get("verdictReasons", [])[:5])))
        pending = need(r, "baselinePending", list)
        if pending:
            bad.append("%d baseline change(s) await confirmation" % len(pending))
        if need(r, "treeClean", bool) is not True:
            bad.append("QA ran on an uncommitted tree")
        head = git("rev-parse", "HEAD")
        commit = need(r, "commit", str)
        if commit != head:
            bad.append("QA tested commit %s, HEAD is %s" % (str(commit)[:10], head[:10]))
        if git("status", "--porcelain"):
            bad.append("working tree is not clean")
        docs = os.path.join(repo, "docs")
        if not os.path.isdir(docs) or os.path.realpath(git("rev-parse", "--show-toplevel", cwd=docs)) != os.path.realpath(docs):
            bad.append("QA repository (docs/) not found")
        else:
            if git("status", "--porcelain", cwd=docs):
                bad.append("QA repository (docs/) is not clean")
            # Progress notes may be committed after a run; the QA code itself may not change.
            if need(r, "docsQaTree", str) != git("rev-parse", "HEAD:qa", cwd=docs):
                bad.append("the QA code (docs/qa) changed since the run")
        try:
            finished = datetime.datetime.fromisoformat(str(need(r, "finishedAt", str)).replace("Z", "+00:00"))
            age = (datetime.datetime.now(datetime.timezone.utc) - finished).total_seconds() / 3600
            if age > max_age or age < -0.1:
                bad.append("QA report is %.0f hours old (limit %d)" % (age, max_age))
        except (TypeError, ValueError):
            bad.append("QA report has no valid finish time")

        rc = need(r, "rc", dict) or {}
        app = need(rc, "app", str, "rc") or ""
        if need(rc, "qaVersion", bool, "rc") is not False:
            bad.append("the tested App was a --qa-version build, not the release version")
        if need(rc, "treeClean", bool, "rc") is not True:
            bad.append("the tested App was built from an uncommitted tree")
        if need(rc, "commit", str, "rc") != commit:
            bad.append("the tested App was built from another commit than the one QA ran on")
        hashes = need(rc, "cdhashes", dict, "rc") or {}
        rc_root = os.path.realpath(os.path.join(qa, "rc")) + os.sep
        if not app or not os.path.isdir(app):
            bad.append("the App QA tested is gone: " + (app or "?"))
        elif not os.path.realpath(app).startswith(rc_root):
            bad.append("the tested App is not under dist/qa/rc/")
        else:
            no_links(app, os.path.dirname(app))
            engine = os.path.join(app, "Contents", "MacOS", "dnswitch-engine")
            for part, p in (("app", app), ("engine", engine)):
                for arch in ("arm64", "x86_64"):
                    want = (hashes.get(part) or {}).get(arch)
                    if not want or cdhash(p, arch) != want:
                        bad.append("%s %s cdhash differs from the tested one" % (part, arch))
    except RuntimeError as e:
        bad.append(str(e))
    except (OSError, ValueError) as e:
        bad.append("QA report unreadable: %s" % e)

    if bad:
        print("\n".join(dict.fromkeys(bad)))
        return 1
    with open(expected_out, "w") as f:
        json.dump(hashes, f)
    print(app)
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "gate":
        sys.exit(gate(sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5]) or 0)
    elif sys.argv[1] == "check":
        check(sys.argv[2], sys.argv[3])
    else:
        sys.exit("usage: qa_gate.py gate|check ...")
