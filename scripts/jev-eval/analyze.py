#!/usr/bin/env python3
"""Scores docs/research/jev-eval/results.jsonl against the frozen dataset's gold labels.

    python3 scripts/jev-eval/analyze.py   # prints markdown tables, writes summary.json

No network. Every decision is one (item, pass, decider, question). "Act" means the
decider picked a real option (not 'none of these'); for Jev an act also needs
confidence >= the threshold, otherwise it counts as "ask".
"""
import json, os, statistics
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
D = os.path.join(ROOT, "docs/research/jev-eval")
NONE = "none of these"

def pct(a, b): return f"{a}/{b} ({100*a/b:.0f}%)" if b else "n/a"
def p95(xs): xs = sorted(xs); return xs[min(len(xs) - 1, int(round(0.95 * (len(xs) - 1))))]

def decisions():
    items = {json.loads(l)["id"]: json.loads(l) for l in open(os.path.join(D, "dataset.jsonl"))}
    rows = [json.loads(l) for l in open(os.path.join(D, "results.jsonl"))]
    out = []
    for r in rows:
        it = items[r["id"]]
        qs = [("command", it.get("gold"))] if it["type"] == "menu" else [("tool", it["gold_tool"]), ("app", it["gold_app"])]
        for q, gold in qs:
            if not gold: continue  # a question with no app named: the app answer is not scored
            a = (r["answer"] or {}).get(q) or {}
            choice = a.get("choice")
            probs = a.get("probabilities") or {}
            out.append({"id": r["id"], "pass": r["pass"], "decider": r["decider"], "q": q if q != "command" else "menu",
                        "split": it["split"], "subtype": it["subtype"], "gold": gold, "choice": choice,
                        "correct": choice in gold, "nofit": gold == [NONE], "conf": a.get("confidence"),
                        "pchoice": probs.get(choice), "pgold": sum(probs.get(g, 0) or 0 for g in gold),
                        "probs": probs, "should_ask": it.get("should_ask", False),
                        "ms": r["ms"], "cost": r["cost"], "error": r["error"], "realtime": it.get("realtime")})
    return items, rows, out

def main():
    items, rows, ds = decisions()
    S = {}
    print(f"calls {len(rows)}, errors {sum(1 for r in rows if r['error'])}, "
          f"spend jev ${sum(r['cost'] for r in rows if r['decider']=='jev'):.4f} llm ${sum(r['cost'] for r in rows if r['decider']=='llm'):.4f}")

    print("\n## Accuracy (decisions = items x 2 shuffles)")
    print("| question | split | subtype | n items | Jev | LLM |")
    print("|---|---|---|---|---|---|")
    keys = sorted({(d["q"], d["split"], d["subtype"]) for d in ds})
    groups = [(q, s, None) for q, s in sorted({(d["q"], d["split"]) for d in ds})] + [(q, s, t) for q, s, t in keys]
    for q, s, t in groups:
        sel = [d for d in ds if d["q"] == q and d["split"] == s and (t is None or d["subtype"] == t)]
        j = [d for d in sel if d["decider"] == "jev"]; l = [d for d in sel if d["decider"] == "llm"]
        n = len({d["id"] for d in sel})
        print(f"| {q} | {s} | {t or '**all**'} | {n} | {pct(sum(d['correct'] for d in j), len(j))} | {pct(sum(d['correct'] for d in l), len(l))} |")
        S[f"acc/{q}/{s}/{t or 'all'}"] = {"n_items": n, "jev": [sum(d['correct'] for d in j), len(j)], "llm": [sum(d['correct'] for d in l), len(l)]}

    print("\n## No-fit items: false-accept = picked a real option when gold is 'none of these'")
    print("| question | n items | Jev false-accept | Jev false-accept at conf>=0.5 | LLM false-accept | realtime (live, audio+screen) |")
    print("|---|---|---|---|---|---|")
    for q in ("menu", "app"):
        sel = [d for d in ds if d["q"] == q and d["nofit"]]
        if not sel: continue
        j = [d for d in sel if d["decider"] == "jev"]; l = [d for d in sel if d["decider"] == "llm"]
        rt = {}
        for d in sel:
            if d["realtime"] and "correct" in d["realtime"]: rt[d["id"]] = d["realtime"]
        rtn = sum(v["n"] for v in rt.values()); rtfa = sum(v["n"] - v["correct"] for v in rt.values())
        print(f"| {q} | {len({d['id'] for d in sel})} | {pct(sum(d['choice'] != NONE for d in j), len(j))} | "
              f"{pct(sum(d['choice'] != NONE and (d['conf'] or 0) >= 0.5 for d in j), len(j))} | "
              f"{pct(sum(d['choice'] != NONE for d in l), len(l))} | {pct(rtfa, rtn) if rtn else 'n/a'} |")

    print("\n## Realtime model on the same trace lists (not re-run; had audio + screenshot)")
    for sub in ("trace_offered", "adversarial", "nofit_trace"):
        rt = [it["realtime"] for it in items.values() if it["type"] == "menu" and it["subtype"] == sub and it["realtime"]]
        a, b = sum(r["correct"] for r in rt), sum(r["n"] for r in rt)
        jd = [d for d in ds if d["decider"] == "jev" and d["subtype"] == sub]; ld = [d for d in ds if d["decider"] == "llm" and d["subtype"] == sub]
        print(f"- {sub}: realtime {pct(a, b)} of turns | Jev {pct(sum(d['correct'] for d in jd), len(jd))} | LLM {pct(sum(d['correct'] for d in ld), len(ld))}")
        S[f"realtime/{sub}"] = [a, b]
    for it in items.values():
        if it["type"] == "routing" and it["realtime"]:
            r = it["realtime"]
            print(f"- routing '{it['utterance']}': realtime tool {r['toolCorrect']}/{r['n']}, app {r['appCorrect']}/{r['n']} (named {', '.join(r['appsNamed'])})")

    print("\n## Order sensitivity (answer differs between the two shuffles)")
    for q in ("menu", "tool", "app"):
        for dec in ("jev", "llm"):
            by = defaultdict(dict)
            for d in ds:
                if d["q"] == q and d["decider"] == dec: by[d["id"]][d["pass"]] = d["choice"]
            pairs = [v for v in by.values() if len(v) == 2]
            flips = sum(v[0] != v[1] for v in pairs)
            print(f"- {q} {dec}: {pct(flips, len(pairs))} items flipped")
            S[f"flips/{q}/{dec}"] = [flips, len(pairs)]

    print("\n## Latency and cost per call (sequential, wall clock incl. network, from Sydney)")
    print("| decider | type | n calls | median ms | p95 ms | mean cost/call USD | mean input tokens |")
    print("|---|---|---|---|---|---|---|")
    for dec in ("jev", "llm"):
        for t in ("menu", "routing"):
            rs = [r for r in rows if r["decider"] == dec and items[r["id"]]["type"] == t and not r["error"]]
            ms = [r["ms"] for r in rs]
            tok = [(r["usage"] or {}).get("input_tokens") or (r["usage"] or {}).get("prompt_tokens") or 0 for r in rs]
            print(f"| {dec} | {t} | {len(rs)} | {statistics.median(ms):.0f} | {p95(ms)} | {statistics.mean(r['cost'] for r in rs):.6f} | {statistics.mean(tok):.0f} |")
            S[f"latency/{dec}/{t}"] = {"n": len(rs), "median": statistics.median(ms), "p95": p95(ms), "meanCost": statistics.mean(r['cost'] for r in rs)}

    print("\n## Jev calibration: accuracy by confidence bucket (all decisions of that question)")
    buckets = [(0, .5), (.5, .7), (.7, .9), (.9, 1.01)]
    for q in ("menu", "tool", "app"):
        j = [d for d in ds if d["decider"] == "jev" and d["q"] == q and d["conf"] is not None]
        cells = []
        for lo, hi in buckets:
            b = [d for d in j if lo <= d["conf"] < hi]
            cells.append(f"[{lo:.1f},{min(hi,1):.1f}] {pct(sum(d['correct'] for d in b), len(b))}")
        brier_top = statistics.mean(((d["pchoice"] or 0) - (1 if d["correct"] else 0)) ** 2 for d in j)
        brier_multi = statistics.mean(sum(((p or 0) - (1 if o in d["gold"] else 0)) ** 2 for o, p in d["probs"].items()) for d in j)
        print(f"- {q} (n={len(j)}): " + " | ".join(cells) + f" | Brier(top-choice) {brier_top:.3f}, Brier(multiclass) {brier_multi:.3f}")
        S[f"brier/{q}"] = [brier_top, brier_multi]

    print("\n## Ask-instead-of-act: Jev acts only when choice != none AND confidence >= t")
    print("coverage = fit decisions acted on; precision = correct among ALL acts (fit + no-fit); false acts on no-fit counted")
    for q in ("menu", "app"):
        j = [d for d in ds if d["decider"] == "jev" and d["q"] == q]
        fit = [d for d in j if not d["nofit"]]; nf = [d for d in j if d["nofit"]]
        print(f"\n{q}: {len(fit)} fit decisions, {len(nf)} no-fit decisions")
        print("| t | coverage (fit acted) | correct among acts | wrong acts (fit) | false acts (no-fit) |")
        print("|---|---|---|---|---|")
        sweep = []
        for t in (0, .3, .5, .6, .7, .8, .9, .95):
            acts = [d for d in j if d["choice"] != NONE and (d["conf"] or 0) >= t]
            good = sum(d["correct"] for d in acts)
            cov = sum(1 for d in acts if not d["nofit"])
            sweep.append((t, cov, len(fit), good, len(acts)))
            print(f"| {t} | {pct(cov, len(fit))} | {pct(good, len(acts))} | {sum(1 for d in acts if not d['nofit'] and not d['correct'])} | {sum(1 for d in acts if d['nofit'])} |")
        S[f"sweep/{q}"] = sweep
        l = [d for d in ds if d["decider"] == "llm" and d["q"] == q]
        la = [d for d in l if d["choice"] != NONE]
        print(f"LLM (no threshold possible): coverage {pct(sum(1 for d in la if not d['nofit']), len([d for d in l if not d['nofit']]))}, "
              f"correct among acts {pct(sum(d['correct'] for d in la), len(la))}, false acts on no-fit {sum(1 for d in la if d['nofit'])}")

    print("\n## Should-ask routing items (ambiguous / misheard): Jev app confidence")
    for d in ds:
        if d["decider"] == "jev" and d["q"] == "app" and d["should_ask"]:
            l = next(x for x in ds if x["decider"] == "llm" and x["q"] == "app" and x["id"] == d["id"] and x["pass"] == d["pass"])
            print(f"- {d['id']} pass{d['pass']}: jev {d['choice']} conf {d['conf']} | llm {l['choice']} | gold {d['gold']}")

    print("\n## Wrong answers (both deciders), for reading")
    for d in ds:
        if not d["correct"]:
            print(f"- {d['id']} p{d['pass']} {d['decider']} {d['q']} [{d['subtype']}] chose {d['choice']!r} conf {d['conf']} gold {d['gold']}")
    json.dump(S, open(os.path.join(D, "summary.json"), "w"), indent=1)

if __name__ == "__main__":
    main()
