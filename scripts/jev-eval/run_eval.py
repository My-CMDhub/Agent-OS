#!/usr/bin/env python3
"""Runs every item of the frozen dataset through Jev and an LLM control on OpenRouter.

    python3 scripts/jev-eval/run_eval.py --smoke     # one tiny Jev call + one LLM call, prints shapes
    python3 scripts/jev-eval/run_eval.py             # full run -> docs/research/jev-eval/results.jsonl

The key is OPENROUTER_JEV_API_KEY in the repo's git-ignored .env, read here at
runtime and only ever placed in the Authorization header — never printed, logged,
passed on a command line or put in a URL.

Jev: Decisions API, POST https://openrouter.ai/api/alpha/decisions, model
typesafe/jev-1.13, `choice` questions whose `criteria` map option name -> description
(https://openrouter.ai/docs/guides/community/jev-tutorial, https://docs.typesafe.ai/primitives/choice).
LLM: chat completions with a strict JSON schema, temperature 0.
Every item runs twice with a different seeded shuffle of its options. Calls are
sequential so latency is one request at a time, wall clock from this machine.
Stops before a call once reported spend passes the cap.
"""
import json, os, random, sys, time, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DATASET = os.path.join(ROOT, "docs/research/jev-eval/dataset.jsonl")
RESULTS = os.path.join(ROOT, "docs/research/jev-eval/results.jsonl")
JEV_URL = "https://openrouter.ai/api/alpha/decisions"
CHAT_URL = "https://openrouter.ai/api/v1/chat/completions"
JEV_MODEL = "typesafe/jev-1.13"
LLM_MODEL = "anthropic/claude-haiku-4.5"
SEED, PASSES, SPEND_CAP_USD = 20260925, 2, 1.90  # 1.90: headroom under the $2.00 cap for the call in flight
NONE = "none of these"

def api_key():
    for line in open(os.path.join(ROOT, ".env")):
        name, _, value = line.strip().partition("=")
        if name == "OPENROUTER_JEV_API_KEY" and value:
            return value.strip().strip('"').strip("'")
    sys.exit("OPENROUTER_JEV_API_KEY missing from .env")

def post(url, body, key):
    request = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST", headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json",
        "X-Title": "jarvis-jev-offline-eval"})
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = json.loads(response.read())
    except urllib.error.HTTPError as error:
        payload = {"httpError": error.code, "body": error.read().decode()[:500]}
    return payload, round((time.perf_counter() - start) * 1000)

def shuffled(options, item_index, pass_index):
    order = list(options)
    random.Random(SEED + item_index * 100 + pass_index).shuffle(order)
    return order

NONE_DESCRIPTION = "No listed command does what the user asked."
APP_NONE_DESCRIPTION = "The app the user means is not in this list."

def jev_body(item, opts):
    if item["type"] == "menu":
        return {"model": JEV_MODEL,
                "state": {"app": item["state"]["app"], "user_request": item["utterance"]},
                "questions": {"command": {
                    "type": "choice",
                    "instructions": f"The user spoke this request to their Mac while using {item['state']['app']}. "
                                    "Which of the app's menu commands does it ask for? Pick 'none of these' if no listed command does it.",
                    "criteria": {o: (NONE_DESCRIPTION if o == NONE else None) for o in opts["options"]}}}}
    return {"model": JEV_MODEL,
            "state": {"user_request": item["utterance"], "frontmost_app": item["state"]["frontmost"],
                      "running_apps": item["state"]["running"]},
            "questions": {
                "tool": {"type": "choice",
                         "instructions": "Which tool should the Mac assistant use for this spoken request?",
                         "criteria": {t: item["tool_descriptions"][t] for t in opts["tool_options"]}},
                "app": {"type": "choice",
                        "instructions": "Which installed app is the request about?",
                        "criteria": {a: (APP_NONE_DESCRIPTION if a == NONE else None) for a in opts["app_options"]}}}}

def numbered(options):
    return "\n".join(f"{i}. {o}" for i, o in enumerate(options, 1))

def llm_body(item, opts):
    system = "You choose options for a Mac voice assistant. Answer with the JSON object only."
    if item["type"] == "menu":
        user = (f"The user said: \"{item['utterance']}\" while using {item['state']['app']}.\n"
                f"Which of the app's menu commands does it ask for? Choose '{NONE}' if no listed command does it.\n\n"
                f"{numbered(opts['options'])}\n\nReturn {{\"index\": <number of the option>}}.")
        schema = {"type": "object", "properties": {"index": {"type": "integer"}}, "required": ["index"], "additionalProperties": False}
    else:
        tools = [f"{t}: {item['tool_descriptions'][t]}" for t in opts["tool_options"]]
        user = (f"The user said: \"{item['utterance']}\". Frontmost app: {item['state']['frontmost']}. "
                f"Running apps: {', '.join(item['state']['running'])}.\n\n"
                f"Which tool should the assistant use?\n{numbered(tools)}\n\n"
                f"Which installed app is the request about? Choose '{NONE}' if the app is not listed.\n{numbered(opts['app_options'])}\n\n"
                "Return {\"tool\": <tool number>, \"app\": <app number>}.")
        schema = {"type": "object", "properties": {"tool": {"type": "integer"}, "app": {"type": "integer"}},
                  "required": ["tool", "app"], "additionalProperties": False}
    return {"model": LLM_MODEL, "temperature": 0, "max_tokens": 40,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "response_format": {"type": "json_schema", "json_schema": {"name": "choice", "strict": True, "schema": schema}}}

def parse_jev(item, payload):
    answers = payload.get("answers") or {}
    out = {}
    for q in (["command"] if item["type"] == "menu" else ["tool", "app"]):
        a = answers.get(q) or {}
        out[q] = {"choice": a.get("choice"), "confidence": a.get("confidence"), "probabilities": a.get("probabilities")}
    return out

def parse_llm(item, opts, payload):
    try:
        content = payload["choices"][0]["message"]["content"]
        data = json.loads(content[content.index("{"):content.rindex("}") + 1])
    except Exception:
        return {"parseError": True}
    def pick(key, options):
        n = data.get(key)
        return options[n - 1] if isinstance(n, int) and 1 <= n <= len(options) else None
    if item["type"] == "menu":
        return {"command": {"choice": pick("index", opts["options"])}}
    return {"tool": {"choice": pick("tool", opts["tool_options"])}, "app": {"choice": pick("app", opts["app_options"])}}

def cost_of(payload):
    return float((payload.get("usage") or {}).get("cost") or 0)

def main():
    key = api_key()
    items = [json.loads(l) for l in open(DATASET)]
    if "--smoke" in sys.argv:
        item = next(i for i in items if i["type"] == "menu" and len(i["options"]) <= 7)
        opts = {"options": item["options"]}
        jev, ms = post(JEV_URL, jev_body(item, opts), key)
        print("JEV", ms, "ms", json.dumps(jev)[:1500])
        llm, ms = post(CHAT_URL, llm_body(item, opts), key)
        print("LLM", ms, "ms", json.dumps({k: llm.get(k) for k in ("model", "choices", "usage", "provider", "httpError", "body")})[:1500])
        return
    spent = 0.0
    with open(RESULTS, "w") as out:
        for index, item in enumerate(items):
            for p in range(PASSES):
                if item["type"] == "menu":
                    opts = {"options": shuffled(item["options"], index, p)}
                else:
                    opts = {"tool_options": shuffled(item["tool_options"], index, p),
                            "app_options": shuffled(item["app_options"], index, p)}
                for decider, url, body_of, parse in (
                        ("jev", JEV_URL, jev_body, lambda pl: parse_jev(item, pl)),
                        ("llm", CHAT_URL, llm_body, lambda pl: parse_llm(item, opts, pl))):
                    if spent >= SPEND_CAP_USD:
                        print(f"SPEND CAP reached: ${spent:.4f}; stopping"); return
                    payload, ms = post(url, body_of(item, opts), key)
                    spent += cost_of(payload)
                    row = {"id": item["id"], "pass": p, "decider": decider, "ms": ms, "cost": cost_of(payload),
                           "usage": payload.get("usage"), "model": payload.get("model"),
                           "error": payload.get("httpError") or payload.get("error"),
                           "answer": parse(payload), "order": opts}
                    out.write(json.dumps(row, ensure_ascii=False) + "\n"); out.flush()
            print(f"{item['id']} done, spent ${spent:.4f}", flush=True)
    print(f"TOTAL spent ${spent:.4f}")

if __name__ == "__main__":
    main()
