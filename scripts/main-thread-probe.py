#!/usr/bin/env python3
"""Main-thread probe: how long each read-only harness verb holds Clicky's main thread.

Run with the harness up AND the stall recorder on:
    open -a Clicky.app --args --harness --main-thread-stall-log
    python3 scripts/main-thread-probe.py              # 20 s per scenario
    python3 scripts/main-thread-probe.py 10           # 10 s per scenario

Why this exists. Harness requests run inside DispatchQueue.main.sync (owner's
ruling 2026-09-11), and the same main thread runs the push-to-talk CGEvent tap
and the overlay's animation timers. Request latency is what a socket client
feels; a main-thread stall is what the hotkey and the cursor feel. Different
numbers, so both are printed.

Attribution. The app owns ~/Library/Logs/Clicky/main-thread-stalls.log and
writes one line per stall over 50 ms, stamped with ProcessInfo.systemUptime.
That is CLOCK_UPTIME_RAW: verified 2026-09-13 on this machine, systemUptime and
clock_gettime_nsec_np(CLOCK_UPTIME_RAW) agreed to 3 us, while CLOCK_MONOTONIC_RAW
was 419 s ahead (it keeps counting through sleep). So each scenario's window is
stamped with time.clock_gettime(time.CLOCK_UPTIME_RAW) and every stall is
assigned to the window its start falls in.

Read-only verbs only. snapshot and menus read the frontmost app, so the app is
brought forward with `open -a` (not a harness verb, not a keystroke), and every
request carries expectApp: a focus drift refuses cheaply instead of measuring
the wrong app, and refusals are counted in the table.
"""
import json, os, socket, subprocess, sys, time

SOCKET_PATH = os.path.expanduser("~/Library/Application Support/Clicky/harness.sock")
STALL_LOG_PATH = os.path.expanduser("~/Library/Logs/Clicky/main-thread-stalls.log")


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


def uptime():
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


def app_running(name):
    return subprocess.run(["pgrep", "-x", name], capture_output=True).returncode == 0


def bring_forward(app):
    subprocess.run(["open", "-a", app])
    time.sleep(1.5)


class ScreenLocked(Exception):
    """Measured 2026-09-13: the screen locked mid-run and two rows became 10,000
    2 ms screenIsLocked refusals — and 12,881 audit lines — about nothing.
    The first lock refusal ends the run; every later request would be the same."""


def run_scenario(name, request, seconds):
    latencies_ms, refusals = [], {}
    started = uptime()
    if request is None:
        time.sleep(seconds)
    else:
        while uptime() < started + seconds:
            sent = uptime()
            response = send(dict(request, id=f"main-thread-probe-{len(latencies_ms)}"))
            latencies_ms.append((uptime() - sent) * 1000)
            if response.get("error") == "screenIsLocked":
                raise ScreenLocked(f"{name}: aborted after {len(latencies_ms)} request(s) because the screen locked")
            if not response.get("ok"):
                error = response.get("error") or "notOk"
                refusals[error] = refusals.get(error, 0) + 1
    return {"name": name, "started": started, "ended": uptime(),
            "latencies": latencies_ms, "refusals": refusals}


def percentile(values, fraction):
    """Nearest rank. With 20 s of samples the choice of method is below the noise."""
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(fraction * (len(ordered) - 1))))]


def read_log_lines(offset):
    with open(STALL_LOG_PATH) as log:
        log.seek(offset)
        return [json.loads(line) for line in log if line.strip()]


def fmt(value):
    return "-" if value is None else f"{value:,.0f}"


def main():
    seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
    try:
        if not send({"verb": "ping"}, timeout=5).get("ok"):
            raise RuntimeError("ping not ok")
    except Exception as error:
        sys.exit(f"harness not answering on {SOCKET_PATH}: {error}")
    if not os.path.exists(STALL_LOG_PATH):
        sys.exit(f"no {STALL_LOG_PATH}: launch Clicky with --main-thread-stall-log")

    offset = os.path.getsize(STALL_LOG_PATH)
    scenarios, notes = [], []

    try:
        scenarios.append(run_scenario("idle", None, seconds))
        bring_forward("Finder")
        scenarios.append(run_scenario("snapshot Finder", {"verb": "snapshot", "expectApp": "Finder"}, seconds))
        scenarios.append(run_scenario("menus Finder", {"verb": "menus", "expectApp": "Finder"}, seconds))
        if app_running("Mail"):
            bring_forward("Mail")
            scenarios.append(run_scenario("snapshot Mail", {"verb": "snapshot", "expectApp": "Mail"}, seconds))
        else:
            notes.append("snapshot Mail skipped: Mail is not running")
        bring_forward("Finder")
        scenarios.append(run_scenario("windows Finder", {"verb": "windows", "app": "Finder", "expectApp": "Finder"}, seconds))
    except ScreenLocked as locked:
        print(f"ABORTED: {locked}; the rows below are only the scenarios that finished before it")
        notes.append(f"ABORTED: {locked}")
    if not scenarios:
        sys.exit("\n".join(notes))

    time.sleep(0.5)  # the app appends on a background queue
    lines = read_log_lines(offset)
    stalls = [line for line in lines if line.get("kind") == "stall"]
    summaries = [line for line in lines if line.get("kind") == "summary"]

    header = f"{'scenario':<16} {'reqs':>5} {'med ms':>7} {'p95 ms':>7} {'max ms':>7} {'stalls>50':>9} {'max stall':>9} {'blocked/10s':>11}  verbs in stalls / refusals"
    print(header)
    print("-" * len(header))
    for scenario in scenarios:
        inside = [s for s in stalls if scenario["started"] <= s["startedAtUptime"] < scenario["ended"]]
        window_seconds = scenario["ended"] - scenario["started"]
        blocked_per_ten = sum(s["durationMs"] for s in inside) / window_seconds * 10
        verbs = sorted({s["harnessVerb"] or "none" for s in inside})
        latencies = scenario["latencies"]
        print(f"{scenario['name']:<16} {len(latencies):>5} {fmt(percentile(latencies, 0.5)):>7} "
              f"{fmt(percentile(latencies, 0.95)):>7} {fmt(max(latencies) if latencies else None):>7} "
              f"{len(inside):>9} {fmt(max((s['durationMs'] for s in inside), default=None)):>9} "
              f"{blocked_per_ten:>11,.0f}  {','.join(verbs) or '-'} / {scenario['refusals'] or '-'}")
        # Measured 2026-09-13: the screen locked mid-run and two rows became 10,000
        # 2 ms screenIsLocked refusals with 0 stalls — a clean-looking row about nothing.
        refused = sum(scenario["refusals"].values())
        if latencies and refused * 2 > len(latencies):
            print(f"  WARNING: {refused} of {len(latencies)} requests refused — this row measures the refusal, not the verb")

    # The impossible-if-broken number: a live recorder writes a summary every 10 s.
    # Without one, every "0 stalls" above is the absence of a recorder, not of stalls.
    total_seconds = scenarios[-1]["ended"] - scenarios[0]["started"]
    print(f"\nrecorder summaries in run: {len(summaries)} (expect ~{int(total_seconds // 10)})")
    if not summaries:
        print("WARNING: no summary lines — the stall recorder is not running; the stall columns are not a measurement")
    for note in notes:
        print(note)


if __name__ == "__main__":
    main()
