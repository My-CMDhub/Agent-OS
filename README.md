# Agent-OS

A macOS accessibility harness for a model to operate the computer through, built to refuse when it should. No model drives it yet.

I forked [`farzaa/clicky`](https://github.com/farzaa/clicky), an on-screen AI buddy that looks at a screenshot and points at things, and replaced how it senses and acts. Instead of guessing pixels, it reads the accessibility tree: the named, positioned controls macOS already publishes for screen readers. Every action goes through local code that can allow it, ask me, or refuse it. An action only counts as done when a second read of the app shows it happened.

Start with [What this does not claim](#what-this-does-not-claim). It's the part I most want people to read, and the part I got wrong at first.

## What I got wrong on the way

These findings changed the design. Each one opens up for the evidence.

<details>
<summary><b>Structure isn't cheaper than pixels.</b> I started reading the tree to save tokens, and the screenshot was cheaper.</summary>

On System Settings (2026-09-07, standard-tier model) the tree cost ~1,966 tokens and the screenshot 1,519. I kept the tree for a different reason: on that screen it offered **165 elements** that can be pressed, verified and waited on, and a screenshot offers none. The tree is meant to stay a local index that the model never sees, so its token cost drops out.

</details>

<details>
<summary><b>Success codes lie.</b> An action counts only when a second look at the app shows it happened.</summary>

`AXError` returned success on **every** write we measured, including ones that changed nothing, and reading the value straight back was wrong in both directions (2026-09-10, System Settings and Finder). Only a second look at the app tracked reality. So the verifier's contract is "the app was seen to react", never "the call returned success".

The planner tests are graded by a separate checker that reads the screen itself, and they assert **which step actually ran**, not just how things ended up.

</details>

<details>
<summary><b>Check order is a safety rule.</b> Finder's <i>Empty Bin…</i> got "try again later" when the answer should have been "never".</summary>

A caller only describes an action; local code decides. Plain navigation goes through. Destructive titles (delete, send, quit, move to bin…) ask a human. Irreversible ones (empty bin, erase, delete permanently, buy, pay, purchase) are refused with no way past.

Finder's **Empty Bin…** is disabled while the bin is empty, so with the "enabled" check first the answer was *try again later*. The never-list now runs ahead of the reachability and enabled checks (only the password-field refusal runs earlier). The ask-list and never-list are unit-tested to share no words.

</details>

<details>
<summary><b>Another process clicked Allow in ~10 ms.</b> Approval took four designs, each broken by a test of the one before.</summary>

1. A `confirmed: true` field could be written by any caller. Approval became a one-time ticket answered on a card.
2. Another process pressed Allow through the accessibility API in **~10 ms** (2026-09-14). Allow now counts only from a hardware input event; a posted click, even one forging its source, was rejected.
3. "Always" rules lived in a file any process running as the user could edit. They moved to the data-protection Keychain; a separate process got `-25300` reading and `-34018` writing (2026-09-14).
4. The selection could change between approval and action. The ticket records what was selected, and a re-issue after the selection changed was refused as stale in **3 ms** (Finder list view, dry run, n=1).

Destructive actions offer Allow once, never Always, because a rule cannot remember *which* file.

</details>

<details>
<summary><b>You can't list the machine's windows.</b> <code>kAXWindows</code> sees the active Space only, and says so with a success code.</summary>

Elsewhere it returns `AXError 0` with an empty list: a silent undercount, not an error. Backgrounded, then frontmost (2026-09-10): Xcode 0 → 2, Cursor 0 → 1, Chrome 0 → 3. TextEdit 0 → 0 is the control that genuinely had no window. `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` agreed: 2 windows for the frontmost app, 0 for all seven others.

You can enumerate the active Space's windows plus whatever is minimised, nothing more. So `focus` activates first and reads second.

</details>

## Try it

You need a Mac on macOS 14.2+ and Xcode. The harness itself needs no API keys.

1. Open `leanring-buddy.xcodeproj`. Under Signing, set your own team and bundle id (the checked-in ones are mine). Build and run from Xcode with Cmd+R. Don't use `xcodebuild` from a terminal; here it invalidated the permission grants.
2. Grant **Accessibility**, **Screen Recording** and **Microphone** when asked.
3. Quit the app and relaunch it with the harness socket open:

   ```bash
   open -a Clicky.app --args --harness
   # or, to force every request to be a dry run:
   open -a Clicky.app --args --harness --harness-dry-run
   ```

4. Talk to it. It's newline-delimited JSON over a Unix socket at `~/Library/Application Support/Clicky/harness.sock`:

   ```bash
   python3 - <<'EOF'
   import json, os, socket
   def send(request):
       s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
       s.connect(os.path.expanduser("~/Library/Application Support/Clicky/harness.sock"))
       s.sendall((json.dumps(request) + "\n").encode())
       buffer = b""
       while b"\n" not in buffer:
           chunk = s.recv(65536)
           if not chunk: break
           buffer += chunk
       return json.loads(buffer.split(b"\n")[0])

   print(send({"verb": "ping"}))
   snap = send({"verb": "snapshot"})     # the frontmost window
   print(snap.get("application"), snap.get("actionableCount"), snap.get("walkStopReasons"))

   # Ask for something with no undo. Dry run, and it is refused anyway.
   send({"verb": "focus", "app": "Finder"})
   r = send({"verb": "menu", "path": ["Finder", "Empty Bin…"], "dryRun": True, "confirmed": True})
   print(r.get("error"), "|", (r.get("kernel") or {}).get("reason"))
   EOF
   ```

   The last request should come back `ok: false`, `error: "kernelRefused"`, with a reason starting `refusing an irreversible action`. `confirmed: true` does nothing; it is only there to show it. On a US-English Mac the menu item is `Empty Trash…`.

The 14 verbs are `ping`, `snapshot`, `press`, `select`, `type`, `open`, `menu`, `menus`, `windows`, `focus`, `look`, `launch`, `status` and `highlight`. `scripts/planner-tests.py` has real multi-step examples. Three files in `~/Library/Application Support/Clicky/` control it: a `HARNESS_DISABLED` file refuses every mutating verb, `harness-policy.json` sets allow / confirm / refuse per app, and `harness-audit.log` records every request.

## What's in here

| Subsystem | File | What it does |
|---|---|---|
| Sensor | `AccessibilitySnapshot.swift` | Batched reads, skips off-screen subtrees, walks only the visible rows of huge lists, dedupes by element identity, names which limit stopped a walk |
| Safety kernel | `ActionSafetyKernel.swift` | Allows plain navigation, asks before destructive actions, refuses irreversible ones and password fields |
| Approval | `HarnessConfirmations.swift`, `ActionBinding.swift`, `ApprovalRulesKeychainStore.swift` | One-time ticket bound to the whole request and to what is selected; only a hardware click approves; "Always" rules live in the Keychain |
| Verifier | `ActionVerifier.swift` | An action counts only when the app is seen to react |
| Trust boundary | `UntrustedText.swift` | Applied at `AccessibilityElementNode.init`, the one place an app's strings enter our types |
| Reachability | `ElementReachability.swift` | Rejects zero-area and off-screen frames; AX scroll verb with a `CGEvent` fallback |
| Settle detection | `WindowSettleObserver.swift` | AXObserver subscribed before acting, debounce, poll floor |
| Escalation | `EscalationLadder.swift` | Structure → targeted crop → full capture, with a point proven to lie inside exactly one candidate |
| Callable interface | `HarnessServer.swift` | Owner-only Unix socket, 14 verbs, own request queue off the main thread, per-app policy, audit log, per-request timing |
| Measurement modes | `MainThreadStallRecorder.swift`, `VoiceStackBenchmark.swift` | Launch-argument instrumentation: main-thread stall log, voice-stack benchmark |

All in `leanring-buddy/` (an upstream typo; the product is named `Clicky`). **61 of the 81 commits** and **27 of the 52 Swift files** are this fork's (24 app sources, 2 test files, 1 benchmark script). The other 25 are Clicky's app shell, voice plumbing, UI and tests.

## What this does not claim

**Who is in control**
- **No model drives this harness yet.** The planner's intents are hand-written. They prove a plan executes, not that anything planned it. The companion app inherited from Clicky still sends a screenshot and parses pixel coordinates.
- **"The tree never enters a prompt" is a design rule, not an enforced one.** `snapshot` returns the actionable elements to any socket client.

**Safety**
- **A hardware click proves a device, not a person.** Virtual-HID drivers and remote screen control arrive the same way. A Touch ID tier for money and credentials is designed but not built.
- **Destructive and irreversible actions are recognised by English words in the title the app wrote.** A checkout button labelled "Place order", "Checkout" or "Transfer" matches nothing and is allowed as an ordinary press. Non-English titles are never matched.
- **Without a policy file, every app is allowed.** Plain button presses do not ask.
- **Password protection is by accessibility subrole.** A credential shown as ordinary text is not caught. The `type` refusal is unit-tested; the capture refusal was verified live once, on a local Safari page.
- **"Always" rules depend on a free personal-team signing profile** that renews every 7 days. The app is not sandboxed.

**What the verifier knows**
- **"The app reacted" is not "the right thing happened".** Verification polls for a change; it does not check intent.
- **There is no rollback.** Nothing reverses a click.

**Coverage**
- **Element identity is name-based.** Across Chrome, Mail and Claude Desktop, 15 names were shared by more than one pressable element, and one of those groups is separated by nothing we read. (An earlier "76 of Chrome's 158 share a name" was mostly our own duplicated walk, retracted in `6488e06`.)
- **Only 26 of 176 System Settings nodes publish `AXPress`** (2026-09-10). Everything else needs a property write or a lower tier.
- **Verbs act on the frontmost app.** `focus` switches Spaces and has no dry-run form.
- **The visible-rows window drops items beyond one screenful.** Finder lost 3 actionable items; no workflow that needed them has been tried.
- **The walk deadline bounds a slow app, not a hung one.**
- **Selection is verified live on outline rows only.** Tables, collection views and Mail's message list are untried.
- **The `CGEvent` fallback is measured against AppKit apps only.** Chromium's and Secure Event Input's behaviour is from research, not runs here.
- **Two clients racing mutating requests is unmeasured.** Requests serialise on one queue by construction.
- **Nothing has been tested on a second display.**

**Voice**
- **There is no voice loop yet.** The worker is deployed and both candidate stacks are benchmarked; neither met its latency target, and answer quality is unmeasured.

## Measured

Dated, from this machine, with sample sizes where the source recorded them. **Tests:** 217 unit tests (Swift Testing). Planner tests 6/6 on two consecutive runs, last run 2026-09-15: six tasks, Finder and System Settings only.

<details>
<summary><b>Harness requests off the main thread</b> (<code>dda6804</code>, 2026-09-15)</summary>

| | before | after | sample |
|---|---|---|---|
| Main-thread stalls over a planner run | 8,520 ms (21 stalls > 50 ms) | max delay 2.8 ms | 1 planner run |
| Ping issued behind a 3 s action | 2,864 ms | 5 ms | median of 5 |

Freeing the main thread removed a guard nobody had designed. Before, anything pressing buttons inside the harness's own panel timed out, because the thread that would answer was busy. Afterwards a caller could have pressed "Remove" on an Always rule, so an explicit `targetIsHarnessItself` refusal shipped in the same commit.

**Reusing the walk that confirmed an action** (`c3f7f3f`): request median `select` 599 → 456 ms, `type` 526 → 450 ms, over 2 + 2 planner runs.

</details>

<details>
<summary><b>Sensor</b> (2026-09-09)</summary>

- Mail's message list is one table with 18,004 rows that reports 11 visible. Walking the visible run plus a screenful either side took Mail from **18,496 nodes to 525**, with actionable / pressable / actionable-now unchanged at 99 / 42 / 23 (`306f7f1`).
- Chrome publishes its tab strip under more than one parent, so a depth-first walk read the same button four times. Deduplicating by element identity: 511 → 434 nodes, shared-name groups 21 → 5, share of pressable elements addressable by a unique name 15% → 66% (`6488e06`).
- The same round-trip probe (unique name → element, no model involved): Cursor and Finder 100%, Chrome 66%, Mail 57%.

</details>

<details>
<summary><b>Voice stack benchmark</b> (2026-09-15)</summary>

20 + 20 runs, 0 errors. First audio, median (p95): Gemini 3.1 Flash Live 1,620 ms (2,517); Deepgram Nova-3 → Claude Haiku 4.5 → gpt-4o-mini-tts 3,451 ms (4,209).

</details>

## Build and test

Swift / SwiftUI, one Xcode project, macOS 14.2+. Build from Xcode, not `xcodebuild` (see [Try it](#try-it)).

```bash
scripts/run-tests.sh              # unit tests, driven through Xcode
scripts/control-probe.sh Finder 3 # sensor control run
python3 scripts/planner-tests.py  # six live tasks, harness running
python3 scripts/main-thread-probe.py
```

All API keys for the companion app live in the Cloudflare worker under `worker/`. No key ships in the binary.

## Attribution

Forked from **[farzaa/clicky](https://github.com/farzaa/clicky)** by Farza Majeed, MIT licensed, and still MIT licensed here. The app shell, companion UI, voice plumbing and the original Clicky concept are his. The accessibility sensor, safety kernel, approval model, verifier, trust boundary, window handling, escalation ladder, harness server and all measurement in this README are this fork's additions.

Implementation was AI-assisted. The architecture, the measurements, the debugging and the retractions were not.

## License

MIT, see [`LICENSE`](LICENSE). Copyright notice retained from upstream.
