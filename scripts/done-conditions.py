#!/usr/bin/env python3
"""Which LinkedIn step conditions can local code see in Chrome's structure?

Owner-present: the owner navigates Chrome to each stage; this only READS
(snapshot forModel + windows over the harness socket) and presses nothing.

    python3 scripts/done-conditions.py capture <stage>   # after each stage
    python3 scripts/done-conditions.py evaluate          # once all are captured

Stages, in order: feed, profile, activity-posts, composer-open, draft-typed, posted.
Each capture is <DONE_CONDITIONS_DIR>/<stage>.json, 0600 in a 0700 directory
(default ~/Library/Logs/Clicky/done-conditions). It keeps the window title and each
element's role, name, selected and value LENGTH only: an element named by its
value (what was typed, or page text) keeps no name, only its length.

`evaluate` mirrors leanring-buddy/DoneCondition.swift: for each step, the
candidate conditions that hold in its own stage and NOT in the stage before it
(a condition that already held earlier cannot detect the step).
"""
import json, os, socket, sys

SOCKET_PATH = os.path.expanduser("~/Library/Application Support/Clicky/harness.sock")
OUT_DIR = os.environ.get("DONE_CONDITIONS_DIR", os.path.expanduser("~/Library/Logs/Clicky/done-conditions"))
CHROME = "com.google.Chrome"
STAGES = ["feed", "profile", "activity-posts", "composer-open", "draft-typed", "posted"]


def send(request, timeout=40.0):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(timeout)
    connection.connect(SOCKET_PATH)
    connection.sendall((json.dumps(request) + "\n").encode())
    buffer = b""
    while b"\n" not in buffer:
        chunk = connection.recv(65536)
        if not chunk:
            break
        buffer += chunk
    connection.close()
    return json.loads(buffer.split(b"\n")[0].decode())


def element(raw):
    by_value = raw.get("nameSource") == "value"
    name = raw.get("name") or ""
    return {"role": raw.get("role"), "name": None if by_value else name,
            # The harness publishes neither today; None is "not read", never False / 0.
            "selected": raw.get("selected"),
            "valueLength": len(name) if by_value else raw.get("valueLength")}


def capture(stage):
    if stage not in STAGES:
        sys.exit(f"stage must be one of {STAGES}")
    snapshot = send({"verb": "snapshot", "forModel": True, "expectApp": CHROME})
    windows = send({"verb": "windows", "app": CHROME, "expectApp": CHROME})
    raw_elements = snapshot.get("elements") or []
    main = [w for w in (windows.get("windows") or []) if w.get("main")] or (windows.get("windows") or [])
    record = {
        "stage": stage,
        "snapshotOk": snapshot.get("ok"), "snapshotError": snapshot.get("error"),
        "walkStopReasons": snapshot.get("walkStopReasons"), "nodeCount": snapshot.get("nodeCount"),
        "windowsOk": windows.get("ok", "windowCount" in windows), "windowsError": windows.get("error"),
        "windowTitle": (main[0].get("title") if main else None) or "",
        "elements": [element(e) for e in raw_elements],
        # Findings, not inventions: a field the harness does not return is a field a session would need added.
        "harnessReturnsSelected": any("selected" in e for e in raw_elements),
        "harnessReturnsValueLength": any("valueLength" in e for e in raw_elements),
    }
    os.makedirs(OUT_DIR, mode=0o700, exist_ok=True)
    path = os.path.join(OUT_DIR, stage + ".json")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(record, f)
    print(f"{stage}: ok={record['snapshotOk']} elements={len(record['elements'])} stop={record['walkStopReasons']} "
          f"selected={record['harnessReturnsSelected']} valueLength={record['harnessReturnsValueLength']} -> {path}")


def holds(condition, snap):
    kind, *args = condition
    find = lambda role, name: next((e for e in snap["elements"] if e["role"] == role and e["name"] == name), None)
    if kind == "windowTitleContains": return args[0] in snap["windowTitle"]
    if kind == "elementPresent": return find(*args) is not None
    if kind == "elementSelected": return (find(*args) or {}).get("selected") is True
    if kind == "elementAbsent": return find(*args) is None
    if kind == "textFieldNonEmpty": return any(e["name"] == args[0] and (e["valueLength"] or 0) > 0 for e in snap["elements"])
    raise ValueError(kind)


def candidates(snap, before):
    keys = lambda s: {(e["role"], e["name"]) for e in s["elements"] if e["name"]}
    yield ("windowTitleContains", snap["windowTitle"])
    for role, name in sorted(keys(snap) - keys(before)): yield ("elementPresent", role, name)
    for role, name in sorted(keys(before) - keys(snap)): yield ("elementAbsent", role, name)
    for e in snap["elements"]:
        if e["selected"] is True and e["name"]: yield ("elementSelected", e["role"], e["name"])
        if (e["valueLength"] or 0) > 0 and e["name"]: yield ("textFieldNonEmpty", e["name"])


def evaluate():
    snaps = {}
    for stage in STAGES:
        path = os.path.join(OUT_DIR, stage + ".json")
        if os.path.exists(path): snaps[stage] = json.load(open(path))
    print("captured:", [s for s in STAGES if s in snaps], "missing:", [s for s in STAGES if s not in snaps])
    for before, stage in zip(STAGES, STAGES[1:]):
        if stage not in snaps or before not in snaps:
            print(f"\n{stage}: not evaluable (needs {before} and {stage})")
            continue
        found = [c for c in candidates(snaps[stage], snaps[before]) if holds(c, snaps[stage]) and not holds(c, snaps[before])]
        print(f"\n{stage} (from {before}): {len(found)} discriminating conditions")
        for c in found[:15]: print("  ", c)
        if not found: print("   none from structure: needs a screenshot check or a harness field")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "capture": capture(sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] == "evaluate": evaluate()
    else: sys.exit(__doc__)
