#!/usr/bin/env python3
"""Doing vs Guiding from the owner's own words (session deciding test 4).

    python3 scripts/mode-classify.py selftest
    python3 scripts/mode-classify.py sheet    # writes docs/superpowers/specs/mode-labels.csv (0600)
    python3 scripts/mode-classify.py score    # after the OWNER fills owner_label
"""
import csv, json, os, re, sys, urllib.request
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "jev-eval"))
from run_eval import api_key, CHAT_URL  # key never printed or copied

LOG = os.path.expanduser("~/Library/Logs/Clicky/voice-transcripts.log")
LABELS = os.path.join(os.path.dirname(__file__), "..", "docs", "superpowers", "specs", "mode-labels.csv")
SWITCH = re.compile(r"\b(let me (do|try)|i'?ll do it|you do it|take over|do the rest)\b", re.I)
GUIDE = re.compile(r"^(how|where|what|which|can you (show|guide|teach|point|highlight))|\b(show me|guide me|teach me|walk me|where is|how do i|how can i)\b", re.I)


def cue_mode(text):
    t = text.strip().lower()
    if SWITCH.search(t): return "switch"
    if GUIDE.search(t): return "guiding"
    return "doing"


def utterances():
    for line in open(LOG):
        row = json.loads(line)
        heard = (row.get("heard") or "").strip()
        if heard: yield row["turnId"], heard


def label_sheet():  # writes the sheet the OWNER corrects; the guess column is only a starting point
    os.umask(0o077)
    with open(LABELS, "w", newline="") as f:
        os.fchmod(f.fileno(), 0o600)  # the owner's words: 0600 even if the file already existed
        w = csv.writer(f); w.writerow(["turnId", "heard", "guess", "owner_label"])
        rows = 0
        for turn_id, heard in utterances():
            w.writerow([turn_id, heard, cue_mode(heard), ""]); rows += 1
    print("sheet", rows, "rows ->", os.path.normpath(LABELS))


def model_mode(text):
    body = {"model": "anthropic/claude-haiku-4.5", "max_tokens": 5, "messages": [{"role": "user", "content":
        "Classify the request to a computer assistant as exactly one word: doing (do it for me), guiding (teach/show me), "
        "switch (change who acts), other (chat, not a task).\nRequest: " + text}]}
    req = urllib.request.Request(CHAT_URL, json.dumps(body).encode(), {"Authorization": "Bearer " + api_key(), "Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=30))["choices"][0]["message"]["content"].strip().lower().split()[0]


def score():
    rows = [r for r in csv.DictReader(open(LABELS)) if r["owner_label"]]
    for name, fn in (("cues", cue_mode), ("haiku", model_mode)):
        hits = sum(fn(r["heard"]) == r["owner_label"] for r in rows)
        print(name, f"{hits}/{len(rows)}")


def selftest():
    cases = {
        "close all my tabs": "doing",
        "open my profile and go into About section": "doing",
        "how do I change the scheme in Xcode": "guiding",
        "where is the agent option": "guiding",
        "show me the models": "guiding",
        "let me do it": "switch",
        "you do it": "switch",
    }
    for text, want in cases.items():
        got = cue_mode(text)
        assert got == want, (text, got, want)
    print("selftest ok", len(cases))


if __name__ == "__main__":
    {"selftest": selftest, "sheet": label_sheet, "score": score}[sys.argv[1]]()
