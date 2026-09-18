# Agent-OS

A macOS accessibility harness built for a model to operate the computer through — and to **refuse** when it should.

Built on top of [`farzaa/clicky`](https://github.com/farzaa/clicky) (MIT). Clicky is an on-screen AI
buddy that can see your screen and point at things. This fork keeps its app shell and adds the part that
has to exist before anything like it belongs near a real machine: a sensor that reads the accessibility
tree instead of guessing at pixels, a safety kernel that asks or refuses before anything moves, an
approval ticket bound to the exact action, and a verifier that re-reads the screen rather than trusting a
success code.

Every capability below comes with the limit that ships with it. What has not been measured is in
[What this does not claim](#what-this-does-not-claim) — the section worth reading first.

---

## What this fork adds

| Subsystem | File | What it does |
|---|---|---|
| **Sensor** | `AccessibilitySnapshot.swift` | Batched attribute reads, off-screen subtree skip, visible-rows window for huge lists, dedupe by element identity, a walk budget that names which limit stopped it |
| **Safety kernel** | `ActionSafetyKernel.swift` | Allows plain navigation, **asks** before destructive actions, **refuses** irreversible ones and password fields outright |
| **Approval** | `HarnessConfirmations.swift`, `ActionBinding.swift`, `ApprovalRulesKeychainStore.swift` | One-time ticket bound to the whole request and to what is selected; only a hardware click can approve; "Always" rules live in the Keychain |
| **Verifier** | `ActionVerifier.swift` | An action counts only when the app is seen to react — never on the API's success code |
| **Trust boundary** | `UntrustedText.swift` | Applied at `AccessibilityElementNode.init`, the one place an app's strings enter our types |
| **Reachability** | `ElementReachability.swift` | Rejects zero-area and off-screen frames; AX scroll verb with a `CGEvent` fallback |
| **Settle detection** | `WindowSettleObserver.swift` | AXObserver subscribed before acting, debounce, poll floor |
| **Escalation** | `EscalationLadder.swift` | Structure → targeted crop → full capture, with a point proven to lie inside exactly one candidate |
| **Callable interface** | `HarnessServer.swift` | Owner-only Unix socket, 14 verbs, requests on their own queue off the main thread, per-app policy, audit log, per-request timing of resolve / act / verify |
| **Measurement modes** | `MainThreadStallRecorder.swift`, `VoiceStackBenchmark.swift` | Launch-argument instrumentation: main-thread stall log, voice-stack benchmark |

**59 of the 79 commits** and **27 of the 52 Swift files** are this fork's (24 app sources, 2 test files,
1 benchmark script). The other 25 are Clicky's app shell, voice plumbing, UI and tests.

---

## The four decisions this repo exists to show

### 1. Read the screen's structure, not its pixels — for the right reason

The sensor walks the macOS accessibility tree for named, positioned controls rather than having a model
guess coordinates from a screenshot.

The original reason was token cost, and **it was wrong**. On System Settings (2026-09-07, standard-tier
model) the tree cost ~1,966 tokens and the screenshot 1,519. The picture was cheaper.

The decision stayed, for a different reason: on that screen the tree offered **165 elements** that can
be pressed, verified and waited on, and a screenshot offers none. The tree is meant to stay a local index
that the model never sees, so its token cost drops out.

### 2. The model proposes; local code decides — and order matters

A caller only describes an action. Deterministic local code decides whether it happens: plain
navigation goes through, destructive titles (delete, send, quit, move to bin…) ask a human, and
irreversible ones (empty bin, erase, delete permanently, buy, pay, purchase) are refused with no way past.

The order of the checks turned out to matter as much as the rules. Finder's **Empty Bin…** is disabled
while the bin is empty, so with the "enabled" check first the answer was *try again later* — when it
should have been *never*. The never-list now runs ahead of the reachability and enabled checks (only the
password-field refusal runs earlier). The ask-list and never-list are unit-tested to share no words.

### 3. Approval is a ticket bound to the exact action

It took four designs, each broken by a test of the one before:

1. A `confirmed: true` field could be written by any caller → approval became a one-time ticket answered on a card.
2. Another process pressed Allow through the accessibility API in **~10 ms** (2026-09-14) → Allow now counts only from a hardware input event; a posted click, even one forging its source, was rejected.
3. "Always" rules lived in a file any process running as the user could edit → they moved to the data-protection Keychain; a separate process got `-25300` reading and `-34018` writing (2026-09-14).
4. The selection could change between approval and action → the ticket records what was selected, and a re-issue after the selection changed was refused as stale in **3 ms** (Finder list view, dry run, n=1).

Destructive actions are **Allow once, never Always** — a rule cannot remember *which* file.

### 4. A write is not done until the screen agrees

`AXError` returned success on **every** write we measured, including ones that changed nothing, and
reading the value straight back was wrong in both directions (2026-09-10, System Settings and Finder).
Only a second look at the app tracked reality — so the verifier's contract is "the app was seen to react",
never "the call returned success".

The planner tests are graded by a separate checker that reads the screen itself, and assert **which step
actually ran**, not just how things ended up.

---

## Measured

Dated, from this machine, with sample sizes where the source recorded them.

**Harness requests off the main thread** (`dda6804`, 2026-09-15)

| | before | after | sample |
|---|---|---|---|
| Main-thread stalls over a planner run | 8,520 ms (21 stalls > 50 ms) | max delay 2.8 ms | 1 planner run |
| Ping issued behind a 3 s action | 2,864 ms | 5 ms | median of 5 |

Freeing the main thread **removed a guard nobody had designed**. Before, anything pressing buttons
inside the harness's own panel timed out, because the thread that would answer was busy. Afterwards a
caller could have pressed "Remove" on an Always rule, so an explicit `targetIsHarnessItself` refusal
shipped in the same commit.

**Reusing the walk that confirmed an action** (`c3f7f3f`): request median `select` 599 → 456 ms,
`type` 526 → 450 ms, over 2 + 2 planner runs.

**Sensor** (2026-09-09)

- Mail's message list is one table with 18,004 rows that reports 11 visible. Walking the visible run plus
  a screenful either side took Mail from **18,496 nodes to 525**, with actionable / pressable /
  actionable-now unchanged at 99 / 42 / 23 (`306f7f1`).
- Chrome publishes its tab strip under more than one parent, so a depth-first walk read the same button
  four times. Deduplicating by element identity: 511 → 434 nodes, shared-name groups 21 → 5, share of
  pressable elements addressable by a unique name 15% → 66% (`6488e06`).
- That same round-trip probe (unique name → element, **no model involved**): Cursor and Finder 100%,
  Chrome 66%, Mail 57%.

**Tests.** 217 unit tests (Swift Testing). Planner tests 6/6 on two consecutive runs, last run
2026-09-15 — six tasks, Finder and System Settings only.

**Voice stack benchmark** (2026-09-15, 20 + 20 runs, 0 errors). First audio, median (p95): Gemini 3.1
Flash Live 1,620 ms (2,517); Deepgram Nova-3 → Claude Haiku 4.5 → gpt-4o-mini-tts 3,451 ms (4,209).

---

## A finding worth knowing if you build anything like this

`kAXWindows` lists windows on the **active Space only**, and otherwise returns `AXError 0` with an empty
list — a silent undercount, not an error. Backgrounded → frontmost (2026-09-10): Xcode 0 → 2, Cursor
0 → 1, Chrome 0 → 3. TextEdit 0 → 0 is the control that genuinely had no window.
`CGWindowListCopyWindowInfo(.optionOnScreenOnly)` agreed: 2 windows for the frontmost app, 0 for all
seven others.

**You cannot enumerate the machine's windows** — only the active Space's, plus whatever is minimised. So
`focus` activates first and reads second.

---

## What this does not claim

**Who is in control**
- **No model drives this harness yet.** The planner's intents are hand-written; they prove a plan executes, not that anything planned it. The companion app inherited from Clicky still sends a screenshot and parses pixel coordinates.
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
- **Element identity is name-based.** Across Chrome, Mail and Claude Desktop, 15 names were shared by more than one pressable element, and one of those groups is separated by nothing we read. *(An earlier "76 of Chrome's 158 share a name" was mostly our own duplicated walk — retracted in `6488e06`.)*
- **Only 26 of 176 System Settings nodes publish `AXPress`** (2026-09-10). Everything else needs a property write or a lower tier.
- **Verbs act on the frontmost app.** `focus` switches Spaces and has no dry-run form.
- **The visible-rows window drops items beyond one screenful.** Finder lost 3 actionable items; no workflow that needed them has been tried.
- **The walk deadline bounds a slow app, not a hung one.**
- **Selection is verified live on outline rows only.** Tables, collection views and Mail's message list are untried.
- **`CGEvent` fallback is measured against AppKit apps only.** Chromium's and Secure Event Input's behaviour is from research, not runs here.
- **Two clients racing mutating requests is unmeasured.** Requests serialise on one queue by construction.
- **Nothing has been tested on a second display.**

**Voice**
- **There is no voice loop yet.** The worker is deployed and both candidate stacks are benchmarked; neither met its latency target, and answer quality is unmeasured.

---

## Build

Swift / SwiftUI, one Xcode project, macOS 14.2+. The product is named `Clicky`; the source folder is
`leanring-buddy` (an upstream typo — renaming it is a large diff with no benefit).

    scripts/run-tests.sh              # unit tests, driven through Xcode
    scripts/control-probe.sh Finder 3 # sensor control run
    python3 scripts/planner-tests.py  # six live tasks, harness running
    python3 scripts/main-thread-probe.py

**Permissions.** The app needs Accessibility, Screen Recording and Microphone. Build from Xcode:
`xcodebuild` from a terminal invalidated those grants here, and re-granting them is slow.

**Keys.** All API keys live in the Cloudflare worker under `worker/`. No key ships in the binary.

---

## Attribution

Forked from **[farzaa/clicky](https://github.com/farzaa/clicky)** by Farza Majeed, MIT licensed, and
still MIT licensed here. The app shell, companion UI, voice plumbing and the original Clicky concept are
his. The accessibility sensor, safety kernel, approval model, verifier, trust boundary, window handling,
escalation ladder, harness server and all measurement in this README are this fork's additions.

Implementation was AI-assisted. The architecture, the measurements, the debugging and the retractions
were not.

## License

MIT — see [`LICENSE`](LICENSE). Copyright notice retained from upstream.
