#!/usr/bin/env python3
"""Builds the frozen Jev-vs-LLM chooser dataset from the voice decision trace.

Offline only: reads ~/Library/Logs/Clicky/voice-decisions.log (schema 1-2, see
RealtimeDecisionTrace in leanring-buddy/RealtimeVoiceVerbs.swift) and, for the
widened Finder list, one saved harness `menus` response (read-only verb). Writes
docs/research/jev-eval/dataset.jsonl (git-ignored). No network, no UI actions.

    python3 scripts/jev-eval/build_dataset.py --finder-menus /path/to/menus.json

Every item carries its gold label explicitly. Privacy: the same filter as
`isPrivateMenuItem` (Recent*/Apple/History/Bookmarks/Profiles, untitled Window
items) is applied to every list, dropped items are never stored, and any quoted
selection name (Finder's `Copy “<file>” as Pathname`) is replaced by
“<selection>” — the app's own filter does NOT drop those (found building this).
"""
import argparse, json, os, random, re, unicodedata
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TRACE = os.path.expanduser("~/Library/Logs/Clicky/voice-decisions.log")
OUT = os.path.join(ROOT, "docs/research/jev-eval/dataset.jsonl")
NONE = "none of these"

# --- privacy filter: a port of RealtimeVoiceVerbs.isPrivateMenuItem ---------
PRIVATE_TOP = {"apple", "history", "bookmarks", "profiles"}
WINDOW_OK = {"zoom", "zoom all", "bring all to front", "arrange in front", "merge all windows", "show all tabs",
             "show tab bar", "hide tab bar", "move tab to new window", "name window", "remove window from set"}

def tokens(text):
    folded = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return [t for t in re.split(r"[^a-z0-9]+", folded) if t]

def is_private(path, shortcut):
    if " ".join(tokens(path[0])) in PRIVATE_TOP: return True
    if any(t.startswith("recent") for p in path for t in tokens(p)): return True
    if len(path) == 2 and tokens(path[0]) == ["window"] and shortcut is None:
        return " ".join(tokens(path[1])) not in WINDOW_OK
    return False

def redact(label):
    return re.sub(r"“[^”]*”", "“<selection>”", label)

def clean(entries):
    """[{path, shortcut}] -> unique redacted 'A > B' strings, private ones dropped."""
    out = []
    for e in entries:
        if is_private(e["path"], e.get("shortcut")): continue
        s = " > ".join(redact(p) for p in e["path"])
        if s not in out: out.append(s)
    return out

# --- gold: fixture phrase -> expected path (make-voice-fixtures.sh + VoiceToolProbeMenus.swift)
FIXTURES = {
    "06-finder-list-view.wav": ("switch finder to list view", "Finder", "View > as List", False),
    "07-finder-icon-view.wav": ("switch finder to icon view", "Finder", "View > as Icons", False),
    "08-finder-path-bar.wav": ("show the path bar in finder", "Finder", "View > Show Path Bar", False),
    "09-finder-new-window.wav": ("open a new finder window", "Finder", "File > New Finder Window", False),
    "12-chrome-new-window.wav": ("open a new window in chrome", "Google Chrome", "File > New window", False),
    "13-cursor-new-window.wav": ("open a new window in cursor", "Cursor", "File > New Window", False),
    "17-cursor-editor-new-window.wav": ("open a new window in the cursor code editor", "Cursor", "File > New Window", False),
    "14-finder-hide-left-panel.wav": ("hide the left panel in finder", "Finder", "View > Hide Sidebar", True),
    "15-finder-rows.wav": ("make finder show everything in rows", "Finder", "View > as List", True),
    "16-finder-path-thing.wav": ("put finder's toolbar path thing on", "Finder", "View > Show Path Bar", True),
}

def load_trace():
    turns = defaultdict(list)
    for line in open(TRACE):
        d = json.loads(line)
        turns[d["turnId"]].append(d)
    for t in turns.values(): t.sort(key=lambda d: d["seq"])
    return turns

def menu_item(i, split, subtype, utterance, app, options, gold, source, realtime=None, note=None):
    opts = [o for o in options if o != NONE] + [NONE]
    assert all(g in opts for g in gold), (utterance, gold)
    return {"id": f"M{i:03d}", "type": "menu", "split": split, "subtype": subtype, "utterance": utterance,
            "state": {"app": app}, "options": opts, "gold": gold, "source": source,
            "realtime": realtime, "note": note}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--finder-menus", required=True, help="saved harness `menus` response for Finder")
    args = ap.parse_args()
    turns = load_trace()
    items = []

    # A / B(i) / B(iii) from the trace: each distinct (fixture, offered set, app) is one item.
    # realtime = what the realtime model pressed next in the same turn (it had audio + a screenshot).
    groups = {}
    for t in turns.values():
        for k, d in enumerate(t):
            if d["tool"] != "find_menu_items" or not d["offered"] or d["fixture"] not in FIXTURES: continue
            opts = clean(d["offered"])
            key = (d["fixture"], d["args"].get("app"), frozenset(opts))
            g = groups.setdefault(key, {"opts": opts, "pressed": []})
            press = next((x for x in t[k + 1:] if x["tool"] == "press_menu"), None)
            nxt_find = next((x for x in t[k + 1:] if x["tool"] == "find_menu_items"), None)
            if press and (nxt_find is None or nxt_find["seq"] > press["seq"]):
                g["pressed"].append(" > ".join(redact(p) for p in press["args"].get("path", [])))
            else:
                g["pressed"].append(None)
    for (fixture, app, _), g in sorted(groups.items(), key=lambda kv: (kv[0][0], len(kv[1]["opts"]))):
        utt, gold_app, gold_path, adversarial = FIXTURES[fixture]
        fits = gold_path in g["opts"] and app == gold_app  # VS Code's "New Window" for a Cursor request is a no-fit
        gold = [gold_path] if fits else [NONE]
        split = "happy" if fits and not adversarial else "unhappy"
        subtype = ("trace_offered" if not adversarial else "adversarial") if fits else "nofit_trace"
        pressed = g["pressed"]
        rt = {"n": len(pressed), "correct": sum(1 for p in pressed if (p is None if fits is False else p in gold)),
              "pressedNothing": sum(1 for p in pressed if p is None),
              "context": "audio+screenshot, chose from this list live"}
        note = None if fits else f"offered by {app}; gold absent ({'wrong app' if app != gold_app else 'state: item not offered'})"
        items.append(menu_item(len(items) + 1, split, subtype, utt, app, g["opts"], gold, "trace", rt, note))

    finder_list = next(g["opts"] for (f, a, _), g in groups.items() if f == "06-finder-list-view.wav")
    finder_small = ["View > Show Path Bar", "View > Show Tab Bar", "View > Hide Status Bar", "View > Customise Touch Bar…"]
    chrome_list = next(g["opts"] for (f, a, _), g in groups.items() if f == "12-chrome-new-window.wav" and len(g["opts"]) == 12)
    cursor_list = next(g["opts"] for (f, a, _), g in groups.items() if a == "Cursor")

    # A authored: plain wording on the same real lists, so happy and unhappy are closer to balanced.
    plain = [
        ("switch finder to column view", "Finder", finder_list, "View > as Columns"),
        ("switch finder to gallery view", "Finder", finder_list, "View > as Gallery"),
        ("show the view options", "Finder", finder_list, "View > Show View Options"),
        ("show the tab bar in finder", "Finder", finder_small, "View > Show Tab Bar"),
        ("hide the status bar", "Finder", finder_small, "View > Hide Status Bar"),
        ("open a new incognito window", "Google Chrome", chrome_list, "File > New Incognito window"),
        ("open a new tab", "Google Chrome", chrome_list, "File > New tab"),
        ("show my downloads in chrome", "Google Chrome", chrome_list, "Window > Downloads"),
        ("close this chrome window", "Google Chrome", chrome_list, "File > Close Window"),
        ("new text file in cursor", "Cursor", cursor_list, "File > New Text File"),
        ("open a new terminal in cursor", "Cursor", cursor_list, "Terminal > New Terminal"),
        ("close the cursor window", "Cursor", cursor_list, "File > Close Window"),
        ("open a new agents window", "Cursor", cursor_list, "File > New Agents Window"),
    ]
    for utt, app, opts, gold in plain:
        items.append(menu_item(len(items) + 1, "happy", "plain_authored", utt, app, opts, [gold], "authored"))

    # B(i) authored adversarial synonyms: no word shared with the target label.
    authored = [
        ("make the files show up as big pictures", "Finder", finder_list, "View > as Icons"),
        ("i want the files stacked in a table with dates", "Finder", finder_list, "View > as List"),
        ("show me the folders side by side in panes", "Finder", finder_list, "View > as Columns"),
        ("show the breadcrumb trail at the bottom", "Finder", finder_small, "View > Show Path Bar"),
        ("spawn another browser window", "Google Chrome", chrome_list, "File > New window"),
        ("i want to browse privately", "Google Chrome", chrome_list, "File > New Incognito window"),
        ("where did my downloads go, show them", "Google Chrome", chrome_list, "Window > Downloads"),
        ("give me a second editor window", "Cursor", cursor_list, "File > New Window"),
        ("start a blank file", "Cursor", cursor_list, "File > New Text File"),
        ("give me a shell", "Cursor", cursor_list, "Terminal > New Terminal"),
    ]
    for utt, app, opts, gold in authored:
        items.append(menu_item(len(items) + 1, "unhappy", "adversarial_authored", utt, app, opts, [gold], "authored"))

    # B(iii) authored no-fit: a real list, a request nothing in it can do.
    nofit = [
        ("make the text rainbow coloured", "Finder", finder_list),
        ("turn on dark mode", "Finder", finder_list),
        ("open a new window in chrome", "Finder", finder_list),
        ("rename this file to report", "Finder", finder_small),
        ("mute the tab that is playing music", "Google Chrome", chrome_list),
        ("translate this page to french", "Google Chrome", chrome_list),
        ("push my changes to github", "Cursor", cursor_list),
        ("make the font bigger", "Cursor", cursor_list),
    ]
    for utt, app, opts in nofit:
        items.append(menu_item(len(items) + 1, "unhappy", "nofit_authored", utt, app, opts, [NONE], "authored"))

    # B(ii) widened lists.
    menus = json.load(open(args.finder_menus))
    assert menus.get("application") == "Finder" and not menus.get("listingStopReasons")
    desk = clean([i for i in menus["items"] if i["enabled"] and not i["hasSubmenu"]])
    assert len(desk) < 255
    desktop = [  # the saved listing is Finder with NO window open (desktop): no view modes, no bars
        ("open a new finder window", "File > New Finder Window"),
        ("go to my downloads", "Go > Downloads"),
        ("make a new folder", "File > New Folder"),
        ("show me the info for this", "File > Get Info"),
        ("take me to the applications folder", "Go > Applications"),
        ("connect to a server", "Go > Connect to Server…"),
        ("tidy the desktop into piles", "View > Use Stacks"),
        ("switch finder to list view", NONE),
        ("show the path bar in finder", NONE),
        ("hide the left panel in finder", NONE),
        ("make finder show everything in rows", NONE),
    ]
    for utt, gold in desktop:
        items.append(menu_item(len(items) + 1, "unhappy", "widened_full" if gold != NONE else "widened_nofit",
                               utt, "Finder", desk, [gold], "harness menus (Finder, desktop, no window)",
                               note=f"{len(desk)} enabled leaves after privacy filter"))
    union = defaultdict(list)  # every Finder / Chrome item ever offered in the trace, one list per app
    for g_key, g in groups.items():
        for o in g["opts"]:
            if o not in union[g_key[1]]: union[g_key[1]].append(o)
    widened_union = [
        ("switch finder to list view", "Finder", "View > as List"),
        ("switch finder to icon view", "Finder", "View > as Icons"),
        ("show the path bar in finder", "Finder", "View > Show Path Bar"),
        ("hide the left panel in finder", "Finder", "View > Hide Sidebar"),
        ("put finder's toolbar path thing on", "Finder", "View > Show Path Bar"),
        ("make finder show everything in rows", "Finder", "View > as List"),
        ("open a new window in chrome", "Google Chrome", "File > New window"),
        ("open an incognito window", "Google Chrome", "File > New Incognito window"),
    ]
    for utt, app, gold in widened_union:
        items.append(menu_item(len(items) + 1, "unhappy", "widened_union", utt, app, union[app], [gold],
                               "union of every list the trace offered for this app",
                               note=f"{len(union[app])} items" + ("; mixes window states (Show AND Hide Path Bar)" if app == "Finder" else "")))

    # C. routing: two questions per item — tool, and app from the installed list.
    apps = sorted({n[:-4] for d in ("/Applications", "/System/Applications", "/System/Applications/Utilities")
                   if os.path.isdir(d) for n in os.listdir(d) if n.endswith(".app")} | {"Finder"})
    tools = {"open_app": "Launch an app, or bring it forward if it is already running.",
             "focus_app": "Switch to an app that is already running.",
             "menu_command": "Run a command inside an app through its menu bar: new window, new document, view modes, show or hide bars.",
             "cannot_do": "None of these tools does what was asked: a question, an explanation, or a system setting."}
    running = ["Finder", "Google Chrome", "Cursor", "Claude", "Terminal"]
    def route(utt, gold_tools, gold_apps, split, subtype, frontmost="Finder", run=running, should_ask=False, realtime=None, note=None):
        assert all(a in apps + [NONE] for a in gold_apps), gold_apps
        items.append({"id": f"R{len(items)+1:03d}", "type": "routing", "split": split, "subtype": subtype,
                      "utterance": utt, "state": {"frontmost": frontmost, "running": run},
                      "tool_options": list(tools), "tool_descriptions": tools, "gold_tool": gold_tools,
                      "app_options": apps + [NONE], "gold_app": gold_apps, "should_ask": should_ask,
                      "source": "fixture" if realtime else "authored", "realtime": realtime, "note": note})

    def rt_route(fixture):
        """Per turn: the realtime model's tool class and first app named."""
        out = []
        for t in turns.values():
            if t[0]["fixture"] != fixture: continue
            names = [d["tool"] for d in t]
            tool = "menu_command" if {"find_menu_items", "press_menu"} & set(names) else names[0]
            app = t[0]["args"].get("name") or t[0]["args"].get("app")
            out.append((tool, app))
        return out
    def rt_summary(fixture, gold_tools, gold_apps):
        r = rt_route(fixture)
        return {"n": len(r), "toolCorrect": sum(t in gold_tools for t, _ in r),
                "appCorrect": sum(a in gold_apps for _, a in r),
                "appsNamed": sorted({a for _, a in r if a}), "context": "audio+screenshot; heard speech, not text"}

    notrun = [a for a in running if a != "Cursor"]
    fixture_routes = [
        ("10-textedit-bring-up.wav", "bring up textedit", ["open_app", "focus_app"], ["TextEdit"], "happy", notrun),
        ("11-textedit-new-document.wav", "new textedit document", ["menu_command"], ["TextEdit"], "unhappy", running),
        ("12-chrome-new-window.wav", "open a new window in chrome", ["menu_command"], ["Google Chrome"], "happy", running),
        ("13-cursor-new-window.wav", "open a new window in cursor", ["menu_command"], ["Cursor"], "unhappy", running),
        ("17-cursor-editor-new-window.wav", "open a new window in the cursor code editor", ["menu_command"], ["Cursor"], "unhappy", running),
        ("06-finder-list-view.wav", "switch finder to list view", ["menu_command"], ["Finder"], "happy", running),
        ("09-finder-new-window.wav", "open a new finder window", ["menu_command"], ["Finder"], "happy", running),
    ]
    for fx, utt, gt, ga, split, run in fixture_routes:
        route(utt, gt, ga, split, "fixture", run=run, realtime=rt_summary(fx, gt, ga))
    happy = [
        ("open system settings for me", ["open_app"], ["System Settings"]),
        ("open safari", ["open_app"], ["Safari"]),
        ("launch xcode", ["open_app"], ["Xcode"]),
        ("open notes", ["open_app"], ["Notes"]),
        ("switch to terminal", ["focus_app", "open_app"], ["Terminal"]),
        ("show the path bar in finder", ["menu_command"], ["Finder"]),
        ("open microsoft word", ["open_app"], ["Microsoft Word"]),
        ("go back to chrome", ["focus_app", "open_app"], ["Google Chrome"]),
        ("open the calendar", ["open_app"], ["Calendar"]),
        ("close this window", ["menu_command"], ["Finder"]),
        ("open messages", ["open_app"], ["Messages"]),
        ("open the calculator", ["open_app"], ["Calculator"]),
        ("open activity monitor", ["open_app"], ["Activity Monitor"]),
        ("switch to cursor", ["focus_app", "open_app"], ["Cursor"]),
        ("open a new tab in chrome", ["menu_command"], ["Google Chrome"]),
        ("open whatsapp", ["open_app"], ["WhatsApp"]),
        ("open visual studio code", ["open_app"], ["Visual Studio Code"]),
    ]
    for utt, gt, ga in happy:
        route(utt, gt, ga, "happy", "authored")
    unhappy = [
        ("what app am i looking at right now", ["cannot_do"], [], "question", False),
        ("how do i change my wallpaper", ["cannot_do"], [], "question", False),
        ("where is the export button", ["cannot_do"], [], "question", False),
        ("what does this error mean", ["cannot_do"], [], "question", False),
        ("turn on do not disturb", ["cannot_do"], [], "system_setting", False),
        ("open a new window in kasa", ["menu_command"], ["Cursor"], "mishearing (Gemini, trace)", True),
        ("open a new window in kassa", ["menu_command"], ["Cursor"], "mishearing (Gemini, trace)", True),
        ("open cursor", ["open_app", "focus_app"], ["Cursor"], "cursor_vs_code", False),
        ("open vs code", ["open_app"], ["Visual Studio Code"], "cursor_vs_code", False),
        ("open the cursor code editor", ["open_app", "focus_app"], ["Cursor"], "cursor_vs_code", False),
        ("open a new window in code", ["menu_command"], ["Visual Studio Code"], "cursor_vs_code (ambiguous)", True),
        ("open spotify", ["open_app"], [NONE], "not_installed", False),
        ("open photoshop", ["open_app"], [NONE], "not_installed", False),
        ("open visual studio", ["open_app"], [NONE, "Visual Studio Code"], "not_installed_near_miss", True),
        ("open chat gpt", ["open_app"], ["ChatGPT"], "near_duplicate (ChatGPT / ChatGPT Classic)", True),
        ("bring up the browser", ["open_app", "focus_app"], ["Google Chrome", "Safari", "Comet"], "generic_name", True),
        ("open settings", ["open_app"], ["System Settings"], "short_name", False),
        ("open the terminal thing", ["open_app", "focus_app"], ["Terminal"], "sloppy", False),
    ]
    for utt, gt, ga, sub, ask in unhappy:
        route(utt, gt, ga, "unhappy", sub, should_ask=ask)

    with open(OUT, "w") as f:
        for it in items: f.write(json.dumps(it, ensure_ascii=False) + "\n")
    by = defaultdict(int)
    for it in items: by[(it["type"], it["split"], it["subtype"])] += 1
    for k in sorted(by): print(by[k], *k)
    print(len(items), "items ->", OUT)

if __name__ == "__main__":
    # self-check of the privacy port and redaction
    assert is_private(["History", "Show Full History"], "⌘Y") and is_private(["File", "Open Recent", "x"], None)
    assert is_private(["Window", "My Page Title"], None) and not is_private(["Window", "Zoom All"], None)
    assert redact("Copy “ passport.pdf” as Pathname") == "Copy “<selection>” as Pathname"
    main()
