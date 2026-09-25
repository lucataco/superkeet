# Superkeet — Product Requirements Document

| | |
|---|---|
| **Product** | Superkeet, a macOS menu bar app for local voice-to-text and voice-driven actions |
| **Current version** | 1.9.0 (`Resources/Info.plist`), with the next release in progress on `main` |
| **Document date** | 2026-09-20 |
| **Status** | Living document. Derived from the shipped app, `README.md`, `docs/actions-mode.md`, `docs/transcription-preservation.md`, the release notes under `docs/releases/`, and the current source tree. Items marked *Proposed* are not yet committed to and are for discussion. |
| **License** | MIT |

---

## 1. Summary

Superkeet lets a Mac user speak instead of type. It lives in the menu bar, records on a global shortcut, transcribes entirely on-device with NVIDIA's Parakeet TDT 0.6B model (through the bundled `parakeet` engine from `lucataco/parakeet-cli`), and puts the text on the clipboard or pastes it into the active app. Nothing leaves the machine.

Since 1.7.0 the same voice input can also **do things**. **Actions Mode** turns a spoken command into tool calls: apps and web pages open natively, common in-app steps become keyboard shortcuts or typed text, and anything broader is planned by Apple's on-device Foundation Models and executed through local MCP (Model Context Protocol) servers under a user-chosen approval policy. The current development thread makes Actions Mode act *while the user is still speaking* and lets one shortcut press open a **listening session** in which several commands can be spoken in a row.

The long-term direction, in the maintainer's words, is that voice replaces the keyboard and mouse for everyday tasks, and that actions happen while the user is still speaking rather than after a round trip.

---

## 2. Problem and opportunity

1. **Cloud dictation is a privacy and latency trade-off.** Most macOS dictation tools stream audio to a server. Users handling confidential text (legal, medical, engineering, personal notes) need transcription that provably never leaves the Mac and keeps working offline.
2. **Dictation stops at text.** Voice tools produce a transcript and leave the user to click through apps. There is no local, private way to say "open Notes and create a new note" and have it happen.
3. **Agent tooling is not built for voice.** MCP servers and computer-use drivers assume a chat interface, large-context cloud models, and vision. A spoken command needs sub-second feedback, a small on-device model, no screenshots, and a safety model a person can understand at a glance.
4. **Setup friction kills local tools.** Local speech models normally require a manual download, a Python environment, or a CLI. A menu bar app has to provision itself.

Superkeet's opportunity is to be the private, self-contained voice layer for macOS: dictation that is always local, plus an action mode that is fast because it is deterministic wherever possible and only falls back to a model when it must.

---

## 3. Goals and non-goals

### Goals

| # | Goal | How we know |
|---|---|---|
| G1 | 100% on-device speech recognition and planning; no cloud dependency after the one-time model download | No network calls during recording, transcription, or planning (verifiable in code and with a packet capture) |
| G2 | Text is never stranded | Every take is copied to the clipboard regardless of settings; recovery commands work without history |
| G3 | Installation is one step | `brew install --cask lucataco/tap/superkeet` or a notarized ZIP; the model downloads itself during onboarding |
| G4 | Actions begin before the sentence ends | An app named in a command launches within ~1 s of being recognised; later native clauses run as soon as the next clause begins |
| G5 | The safety model is legible and conservative by default | Three approval policies; destructive tools always ask; every call audited locally |
| G6 | The microphone is only open when the user asked for it | No always-on listening; sessions are explicit and visible in the HUD and menu bar |
| G7 | Reliability under real audio | Bounded engine sessions, explicit completion states, no silent loss |

### Non-goals (current)

- Cloud transcription or cloud LLM planning of any kind.
- Intel Macs (Apple Silicon is a readiness check).
- Mac App Store distribution (Actions Mode spawns local processes and is incompatible with the sandbox).
- Bundling Node, Python, or MCP servers. Servers are user-installed.
- Vision-based computer use. The on-device model is text-only.
- Always-on or wake-word listening.
- In-app auto-update. Updates come through Homebrew or GitHub Releases.
- Windows or Linux.
- Localisation of command grammar beyond English.

---

## 4. Users

| Persona | Needs | What matters most |
|---|---|---|
| **Private dictator** — writer, lawyer, clinician, engineer who dictates into any app | Fast, accurate local transcription; clipboard-first; optional paste; nothing stored unless asked | Privacy, "never lose text", low friction |
| **Power user / developer** — uses Chrome DevTools MCP, Cua Driver, custom MCP servers | Speak multi-step commands; drive apps and browser tabs; tune approval policy; read the audit log | Speed, determinism, control, visibility |
| **Accessibility-motivated user** — reduced keyboard/mouse use | Reliable hold-to-talk and toggle shortcuts; clear status; voice-driven app control | Reliability, predictable behaviour, feedback |
| **Maintainer / contributor** | Buildable with `swift build`; strong pure-logic test coverage; CI that mirrors local checks | Testability, conventions in `AGENTS.md` and `CONTRIBUTING.md` |

---

## 5. Product principles

1. **Local by construction.** Speech, planning, history, stats, secrets, and audit all stay on the Mac. Any proposal that adds a network dependency to the core loop is out.
2. **Clipboard is the floor.** Auto-paste and history are additive. No combination of settings can lose a transcript.
3. **Deterministic before generative.** If a spoken clause can be handled by string matching against installed apps, a shortcut table, or a typing recipe, it never reaches the model. The model is the fallback, not the default.
4. **Act while speaking, but never on a guess.** Early actions require an exact, unambiguous match to an installed app. Sound-alike matching is only used after the final transcript.
5. **Explicit sessions, visible microphone.** One shortcut opens a listening session; the same shortcut or Escape closes it. The HUD pill is the indicator. The microphone is off whenever the pill is gone.
6. **Approval scales with risk, and destructive always asks.** Read-only runs, "changes state" asks by default, destructive asks under every policy.
7. **Don't repeat what already happened.** Early launches and early steps are recognised as done by the final command instead of being executed twice.
8. **Every action is auditable.** Tool, redacted arguments, outcome, latency, and reason are logged locally.
9. **Fail closed on invented handles.** Session labels, element tokens, snapshot ids the model produces on its own are dropped so servers reject rather than act on a hallucination.
10. **Escape always stops everything.** Recording, listening session, running action, and queued commands.

---

## 6. Scope overview

Status legend: **Shipped** (in 1.8.0 or earlier), **In progress** (implemented on `main`, uncommitted as of the document date, targeted at the next release), **Proposed** (not started).

| Area | Capability | Status |
|---|---|---|
| Dictation | Toggle and push-to-talk recording, local transcription, clipboard/auto-paste/history | Shipped |
| Dictation | Filler removal, app-scoped phrase replacements, spoken corrections, transcript recovery | Shipped |
| Feedback | Six overlay styles, sound cues, menu bar state, outcome flash | Shipped |
| Setup | Four-step onboarding, self-provisioning model download, readiness checklist and diagnostics | Shipped |
| Setup | Actions Mode onboarding step on macOS 26 | In progress |
| Actions | Built-in `open_app`, `open_url`, `press_shortcut`; multi-step commands; plan card; Approve Similar | Shipped |
| Actions | Instant app launch from interim text; per-step planner sessions; observation projection | Shipped |
| Actions | Listening session (one press on, one press off, dispatch on pause); hold-to-run shortcut | In progress |
| Actions | Native clauses run while speaking (opens, searches, shortcuts, typing) with handoff to the command | In progress |
| Actions | Built-in `type_text`; native web search; spoken URL joining; sound-alike app resolution; everyday aliases | In progress |
| Actions | Acknowledgement/filler dropping ("Great, thanks." runs nothing); lead-in and trailing-politeness stripping | In progress |
| Actions | Observation handle binding (pid/window/snapshot/token/session filled in by Superkeet); automatic `list_windows`; session revival | In progress |
| Actions | Interaction tools reclassified as "changes state"; housekeeping tools withheld; latency fields in audit log | In progress |
| Actions | Carried app between utterances of a session; restore minimized windows on "open" | In progress |
| Actions | Approval policy renamed "Just Do It (YOLO)" and moved under the Actions Mode toggle | In progress |
| Infra | MCP warm connect at launch / on enable; `install.sh` picks a stable signing identity | In progress |
| — | Human-recorded accuracy evaluation; audio retention/replay; further roadmap items | Proposed (see §15) |

---

## 7. Functional requirements

Requirement IDs are stable handles for discussion and issue tracking. "Must" is required behaviour; "Should" is expected unless there is a documented reason.

### 7.1 Menu bar app and lifecycle

| ID | Requirement | Status |
|---|---|---|
| APP-1 | The app runs as a menu bar extra with no Dock icon (`LSUIElement`). | Shipped |
| APP-2 | The menu offers: start/stop recording; Run an Action or Start/Stop Listening (when Actions Mode is on); Auto-Approve Actions toggle; Copy Last Transcript; Copy Original Transcript; Undo Text Changes and Copy; History; Settings; Quit. | Shipped / In progress (listening labels) |
| APP-3 | The icon reflects state: idle, red mic while recording, orange while transcribing, blue waveform while listening for a command, purple wand while an action runs. | Shipped |
| APP-4 | Launch at Login is offered through `SMAppService` and always read from the system so it cannot drift. | Shipped |
| APP-5 | Appearance follows System, Light, or Dark by preference. | Shipped |
| APP-6 | Quitting flushes pending history and usage-stat writes, cancels in-flight model downloads, and shuts the daemon down cleanly (SIGINT/SIGTERM handled). | Shipped |
| APP-7 | Every managed window (settings, onboarding, history, overlay, HUD) can be opened and closed repeatedly without teardown crashes. | Shipped |

### 7.2 Shortcuts

| ID | Requirement | Status |
|---|---|---|
| KEY-1 | Four configurable global shortcuts: Toggle Recording (default ⌥Space), Push to Talk (default fn), Run an Action (default ⌥⇧Space, shown when Actions Mode is on), Hold to Run an Action (default ⌃⇧Space, shown when Actions Mode is on). | Shipped / In progress (hold-to-run) |
| KEY-2 | Duplicate assignments across slots are rejected in Settings. | Shipped |
| KEY-3 | Handled shortcut events are consumed so they do not leak into the active app; toggle autorepeat is consumed. | Shipped |
| KEY-4 | Push-to-talk release always ends the recording it started, even if the mode was switched off mid-press or a shortcut recorder opened. | Shipped |
| KEY-5 | Escape cancels a recording (true daemon `cancel`, no engine restart), closes a listening session without dispatching, stops the active action, and clears queued commands. During Actions Mode the key still reaches the focused app. | Shipped / In progress (session) |
| KEY-6 | Shortcut handling runs on a dedicated thread so a busy settings window never delays typing in other apps. | Shipped |
| KEY-7 | The event tap retries setup if Accessibility is granted later; a failed setup does not leak the tap. | Shipped |

### 7.3 Dictation recording and transcription

| ID | Requirement | Status |
|---|---|---|
| DIC-1 | Recording starts only after the daemon confirms; a pending start can be cancelled by a second press or key release. | Shipped |
| DIC-2 | Audio is transcribed on-device by the bundled `parakeet serve` daemon over a Unix socket using JSON commands (`start`, `stop`, `cancel`, `status`, `shutdown`). | Shipped |
| DIC-3 | The client speaks daemon protocols 1 and 2 and ignores unknown event types so app and engine releases need not be lock-stepped. Malformed events or an unsupported protocol version fail the session explicitly. | Shipped |
| DIC-4 | Transcripts are delivered as complete NDJSON messages; UTF-8 split across reads is handled; a message over 8 MiB fails explicitly rather than keeping a suffix. | Shipped |
| DIC-5 | Every recording has a definite outcome: Copied, Pasted, Partial transcript, No speech, Failed, Command, or Nothing to do. The outcome is shown in the overlay/menu bar and announced for accessibility. | Shipped / In progress ("Nothing to do") |
| DIC-6 | A new recording waits for the pending completion; recording is blocked until then. | Shipped |
| DIC-7 | Overflow counters and segment failures from the engine travel with completion and are surfaced as a partial-result warning. | Shipped |
| DIC-8 | The user can pick the audio input device; the engine restarts automatically on change. Device names match CoreAudio names shown by the engine. | Shipped |
| DIC-9 | An idle engine can be shut down after a configurable number of minutes (default: never). | Shipped |
| DIC-10 | Cancelling a recording probes engine status for up to 1.5 s and restarts the daemon only if it never returns to idle. | In progress |

### 7.4 Output routing and recovery

| ID | Requirement | Status |
|---|---|---|
| OUT-1 | Every transcript is copied to the clipboard. This cannot be turned off. | Shipped |
| OUT-2 | Auto-paste is opt-in (default off). Before posting ⌘V it verifies the target app is the one active when recording started, that it is frontmost, that Accessibility is granted, and that the clipboard generation is the expected one. | Shipped |
| OUT-3 | With auto-paste on, the user chooses whether the transcript stays on the clipboard or the previous clipboard is restored; restoration never overwrites newer user clipboard changes. | Shipped |
| OUT-4 | History is opt-in (default off), local, capped at 1,000 records, stored with restricted permissions, and includes original text and partial status. Older history files remain readable. | Shipped |
| OUT-5 | Copy Last Transcript, Copy Original Transcript, and Undo Text Changes and Copy work without history. Undo copies to the clipboard; it never edits another app's document. | Shipped |
| OUT-6 | Command Mode takes never enter the clipboard/paste path. | Shipped |

### 7.5 Transcript processing

| ID | Requirement | Status |
|---|---|---|
| TXT-1 | Optional filler removal strips only `uh`, `uhh`, `um`, `umm`. `er`, `err`, `hmm`, `ah`, `like`, negations, and deliberate repetitions stay literal. | Shipped |
| TXT-2 | Whole-phrase replacements, optionally scoped to an app bundle id. App-specific rules win, longer phrases win, replacements never cascade. | Shipped |
| TXT-3 | Optional spoken corrections as standalone punctuated clauses: `scratch that`, `replace X with Y`, `undo last correction`. Ambiguous targets stay literal; malformed commands never crash. | Shipped |
| TXT-4 | Command Mode applies phrase replacements only; filler removal and spoken corrections never alter command arguments. | Shipped |

### 7.6 Recording feedback

| ID | Requirement | Status |
|---|---|---|
| FBK-1 | Overlay styles: Mini (dot pill, bottom centre), Classic (bar equaliser), Cursor Waveform (follows pointer), Gradient Island (beside camera), Wide Notch (around camera), None. | Shipped |
| FBK-2 | The overlay stays up through "Transcribing…" and flashes the outcome before hiding. | Shipped |
| FBK-3 | Sound cues: System Cue or No Sound, on start and stop. Inside a listening session one start and one stop sound play for the whole session; nothing plays per utterance and the recording overlay stays hidden because the HUD pill is the indicator. | Shipped / In progress (session behaviour) |
| FBK-4 | The level meter's audio graph is built once at startup and shared with the interim recogniser through one microphone tap, so the first recording's overlay appears without HAL setup on the hot path. | Shipped |

### 7.7 History and usage statistics

| ID | Requirement | Status |
|---|---|---|
| HIS-1 | History view is searchable and supports delete and clear. | Shipped |
| HIS-2 | Usage stats store per-day counts only (words, seconds, sessions), never text, and work whether or not history is on. They power the Settings header: words dictated, average WPM, estimated time saved (against 40 WPM typing), and current streak. | Shipped |
| HIS-3 | History and stats persist through a debounced writer with revision checks; unreadable originals are backed up before first replacement and persistence errors are shown in the UI. | Shipped |
| HIS-4 | Stats can be reset from Settings. | Shipped |

### 7.8 Onboarding and setup diagnostics

| ID | Requirement | Status |
|---|---|---|
| ONB-1 | Onboarding steps: Welcome, Permissions, Output mode, Actions (macOS 26 only), Ready. The model download starts on the first screen and shows as a footer progress bar. | Shipped / In progress (Actions step) |
| ONB-2 | The Accessibility prompt is deferred to the Permissions step; a pre-denied microphone sends the user to System Settings instead of a no-op button. | Shipped |
| ONB-3 | Setup is verified (daemon starts, engine ready) before onboarding is marked complete. | Shipped |
| ONB-4 | Readiness checks: microphone permission, input device, engine binary, speech model, runtime directory, Accessibility, Apple Silicon architecture, Apple Intelligence (for Actions). Passing checks collapse to one "ready" line; failing checks show with a fix action. | Shipped |
| ONB-5 | Diagnostics show engine path, model status, runtime directory, daemon state, and the latest daemon stderr excerpt; a report can be exported. | Shipped |
| ONB-6 | Readiness refreshes when returning from System Settings and on state transitions, not on every progress tick. | Shipped |

### 7.9 Speech engine lifecycle and model provisioning

| ID | Requirement | Status |
|---|---|---|
| ENG-1 | The release app launches only the embedded `parakeet` binary. Development builds locate an engine via `PARAKEET_CLI_PATH`, `PARAKEET_BINARY_PATH`, `PARAKEET_SOURCE_DIR`, a sibling checkout, or a pinned bootstrap checkout built with Cargo. Invalid explicit overrides fail rather than selecting another executable. | Shipped |
| ENG-2 | On first run the ~670 MB INT8 model is downloaded via `parakeet download --progress json`, with free-disk precheck, SHA-256 verification, per-file progress, retry, and cancellation on quit. The daemon start path provisions the model if onboarding was skipped. | Shipped |
| ENG-3 | The model directory can be overridden; `--model-dir` is always passed so download and serve agree. | Shipped |
| ENG-4 | Daemon startup waits for readiness instead of a fixed delay; failures surface diagnostics; duplicate starts are prevented; unreachable processes are cleaned up; stubborn processes are killed on timeout. | Shipped |
| ENG-5 | Crash recovery uses bounded restart backoff; short-lived ready/crash cycles preserve restart history and a sustained healthy run resets it. | Shipped |
| ENG-6 | The bundled engine version is pinned (currently parakeet-cli v0.1.9, protocol 2) in `install.sh`, the release workflow, and `DevelopmentEngineLocator`. | Shipped |

### 7.10 Actions Mode

#### 7.10.1 Enablement and availability

| ID | Requirement | Status |
|---|---|---|
| ACT-1 | Actions Mode is off by default and fully separate from dictation. | Shipped |
| ACT-2 | It requires macOS 26 with Apple Intelligence enabled. On older macOS the Actions tab and onboarding step are hidden; with Apple Intelligence off, the tab explains how to enable it. The rest of the app is unaffected. | Shipped |
| ACT-3 | Turning Actions Mode on (in onboarding or Settings) warms the installed-app inventory and connects enabled MCP servers so the first command does not pay for a cold start. | In progress |

#### 7.10.2 Listening session and command capture

| ID | Requirement | Status |
|---|---|---|
| LSN-1 | Pressing Run an Action opens a **listening session**: the microphone opens, the HUD pill reads "Go ahead, I'm listening.", and each utterance is dispatched as its own command when the end of the interim text has not moved for 1 s. The microphone reopens as soon as the engine is idle again. | In progress |
| LSN-2 | Pressing the shortcut again closes the session and runs whatever was being said; Escape closes it and drops the take. Two consecutive failed takes or a stopped engine also close it. | In progress |
| LSN-3 | The microphone is never open outside a session. Nothing auto-arms listening. | In progress |
| LSN-4 | The session is a setting ("Keep listening between commands", default on). With it off, the shortcut records one take: press to start, press to run. | In progress |
| LSN-5 | Hold to Run an Action always records a single take while held. | In progress |
| LSN-6 | The app a command ended up acting in carries to the next utterance of the same session, so "type hello" after "open Notes" targets Notes with no model call. A named app replaces it; a quit app is ignored; the carried app is forgotten when the session ends. | In progress |
| LSN-7 | Utterances that are only acknowledgements or filler ("Great. Okay, thanks.") are ignored with the outcome "Nothing to do" and run nothing. | In progress |
| LSN-8 | The HUD subtitle shows the shortcut that stops the session and how many commands have run; a Stop button does the same as Escape. | In progress |

#### 7.10.3 Live recognition and acting while speaking

| ID | Requirement | Status |
|---|---|---|
| LIV-1 | Command Mode recordings receive interim text from the Parakeet engine (protocol 2) or, as a fallback on macOS 26 while an older engine runs, from Apple's on-device `SpeechAnalyzer`. The final transcript always comes from Parakeet. Dictation never requests partials. | Shipped |
| LIV-2 | The HUD shows the live words with a cursor while recording, then "Transcribing…" with the last text until the final transcript lands. | Shipped |
| LIV-3 | **Instant app launch** (default on): when the running text says `open`/`launch`/`pull up`/`fire up`/`start`/`show me ‹app›` (or `switch to`/`activate`/`bring up`/`go to ‹running app›`) and the name resolves exactly to an installed app with no other installed name extending it, the app opens immediately without approval. Nothing commits on a URL, an active-tab scope, or an unresolved name. The decision happens at most once per recording and is never undone. | Shipped |
| LIV-4 | The early launch does not wait for the app's window; a later step that acts inside the app waits for the window first. | In progress |
| LIV-5 | **Native clauses while speaking:** every later clause the native router can carry out (open, URL, web search, ⌘N-style shortcut, typing) runs as soon as the next clause has begun or the text ends in "and"/"then". The last clause waits for the final transcript. The first clause that needs the planner blocks early execution for the rest of the utterance. Steps run strictly in order after the launch. | In progress |
| LIV-6 | Early shortcuts and typing run only when the approval policy would not have asked about them (⌘N, ⌘T and `type_text` under the default policy; all "changes state" under Just Do It; nothing under Ask Before Every Tool). Opens and URLs follow the Instant App Launch toggle. | In progress |
| LIV-7 | When the final transcript arrives, the launch and early steps are handed to the command, which waits for them, lists what ran ("Pressed ⌘N in Notes while you were speaking"), and marks matching clauses **Already done** rather than repeating them. A failed early step is simply done again. | In progress |
| LIV-8 | If the final transcript names a different app than the one launched early, the launched app stays open, the command opens the app it asked for, and the disagreement is logged. | Shipped |

#### 7.10.4 Command understanding

| ID | Requirement | Status |
|---|---|---|
| CMD-1 | Commands are split into clauses at `and then`, `then`, `;`, newline, and at `and`, `,`, or a sentence end followed by whitespace **when a new instruction follows** (a known verb or a web address) **or when only filler follows**. Quoted text is never split. `search for Dr. Smith`, `youtube.com`, `3.5` stay whole. | Shipped / In progress (sentence ends, verb gating) |
| CMD-2 | Lead-ins ("hey", "please", "let's", "can you", "I want to", "and once you're there", …) are stripped before verb detection; trailing politeness ("for me", "please", "thanks") is stripped from app names and search queries but never from text to be typed. The live detector and the final command use the same lists. | In progress |
| CMD-3 | Clauses that carry no instruction (acknowledgements, bare connectors, short prepositional context such as "inside this new note") are dropped rather than sent to the planner. | In progress |
| CMD-4 | Spoken web addresses are joined before URL detection ("x dot com" → `x.com`, "youtube dot com slash trending" → `youtube.com/trending`) for real top-level domains only. | In progress |
| CMD-5 | Intent extraction recognises open/switch, click, type, press, scroll, web search (many phrasings), and active-tab scope. Active-tab requests are never split. | Shipped / In progress (new verbs) |
| CMD-6 | App names resolve through registered bundle ids and aliases, then case-insensitive matches in `/Applications`, `~/Applications`, `/System/Applications` (with Utilities). Trailing "app"/"browser" and leading "the"/"new"/"my"/"that" are ignored. Everyday aliases include Chrome, VS Code, camera → Photo Booth, email → Mail, settings → System Settings, calc. | Shipped / In progress (aliases) |
| CMD-7 | After the final transcript only, an unresolved name may match a sound-alike installed app within three edits and the same Soundex key ("the crown" → Google Chrome). Prefixes do not qualify. Names over six words are refused before any disk scan. Lookups use the memoized inventory. | In progress |
| CMD-8 | An unresolved open target with no current app opens a Google "I'm Feeling Lucky" URL; with a current or carried app it goes to the planner with that app as context; an explicit "website/site/page" suffix always selects the web. | In progress |

#### 7.10.5 Built-in native tools

| ID | Requirement | Status |
|---|---|---|
| NAT-1 | `open_app {name}`: launches or brings forward an installed app via `NSWorkspace`, waits up to 4 s for an ordinary window when asked to, and reports name, pid, bundle id, and window state. A running app is unhidden, its minimized windows restored through Accessibility, and activated. | Shipped / In progress (restore) |
| NAT-2 | `open_url {url, browser?}`: opens a URL in the default or a named browser; bare domains are upgraded to `https://`. A URL step with no browser uses the browser an earlier step opened. | Shipped |
| NAT-3 | `press_shortcut {app, keys}`: activates the app, waits up to 1.5 s until it is frontmost, then posts the chord. Fixed key table (letters, digits, return, tab, space, delete, escape, arrows, F-keys; cmd/shift/option/control). Nothing is sent if the app is not running or not frontmost. | Shipped |
| NAT-4 | `type_text {app, text}`: types up to 4,000 characters at the insertion point with synthetic Unicode key events in 20-character chunks, Return per newline, after the app is confirmed frontmost. | In progress |
| NAT-5 | **Shortcut recipes** map spoken verbs to chords without the model: create/make/start/compose/write/add/open a new ‹thing› → ⌘N (⌘T for a tab); save → ⌘S; close → ⌘W; undo/redo → ⌘Z/⇧⌘Z; select all → ⌘A; quit → ⌘Q. A trailing "in ‹app›" names the target; otherwise the current app. | Shipped |
| NAT-6 | **Typing recipes** map "type/write/enter/put/insert ‹text›", "make the title say ‹text›", "set the heading to ‹text›", "name it ‹text›" to `type_text`. Surrounding quotes and a sentence-final period are dropped. A trailing "in ‹app›" that is not a running app is part of the text. With nothing opened, the frontmost app is the target. "write a new note" is ⌘N, never typed text. | In progress |
| NAT-7 | **Native web search:** "search for / google / look up ‹query›" opens a search URL in the default browser, the named browser, or the browser an earlier step opened, with no model call. Trailing "in Chrome" is removed from the query; "restaurants in Paris" stays. | In progress |
| NAT-8 | Compound requests containing an open, shortcut, or typing clause run with the built-in tools even when no MCP server is enabled. | Shipped |

#### 7.10.6 Planner (on-device model)

| ID | Requirement | Status |
|---|---|---|
| PLN-1 | Steps that no native route handles are planned by Apple's Foundation Models framework on-device, one fresh session per step, with context describing the full command, the step, what earlier steps did, and which apps are open with pids and window state. | Shipped |
| PLN-2 | Tools are ranked by relevance to the spoken request, capped at 40, and further limited to what fits the measured model context (4,096 tokens on macOS 26.0; real token cost measured on 26.4+). Round-robin keeps every enabled server represented. Common words do not inflate relevance. | Shipped |
| PLN-3 | Housekeeping tools (permissions, updates, recording, cursor, config, session management, `kill_app`, `zoom`, …) are withheld from every plan. | In progress |
| PLN-4 | Tool results fed back to the model are limited to 800 characters. Structured computer-use observations are **projected** into ranked, compact lines (labelled actionable elements first, matched menu items, text bodies as character counts) rather than truncated; screenshots are not requested unless the model asks. | Shipped |
| PLN-5 | Within a command, identical calls reuse their result. Live-state read-only tools always run fresh; every successful state change drops cached read-only results; mutations are reused, never repeated. | Shipped |
| PLN-6 | Context overflow before any tool ran retries with a smaller tool set (up to 2 retries); overflow after tools ran continues once from a condensed progress summary. If it still cannot fit, the user is told to narrow the request or enable fewer servers. | Shipped |
| PLN-7 | The model's `open_app` for an app already opened in the run is satisfied from the run instead of relaunching. | Shipped |
| PLN-8 | **Observation handle binding:** `session`, `element_token`, `snapshot_id`, and server-default options are removed from the schemas the model sees. The model names controls by `element_index`; Superkeet fills token, snapshot id, pid, and window id from the latest `get_window_state`/`list_windows`/`list_apps`. Missing pid comes from the current app, then the latest observation, then the frontmost window. Invented handles are dropped so the server fails closed. | In progress |
| PLN-9 | When a call needs a window id Superkeet has not observed for that pid, Superkeet runs `list_windows` itself (outside the step budget) and completes the call. Every session-aware tool receives one per-command label (`sk-xxxxxxxx`). | In progress |
| PLN-10 | If a tool reports its session has ended, Superkeet calls `start_session` with that id once and retries the same call within its timeout. | In progress |
| PLN-11 | Planner instructions explain `press_shortcut`, `type_text`, URL schemes, browser selection, active-tab page identification (focus evidence required), and the Cloudflare DNS deep-link template. | Shipped / In progress |

#### 7.10.7 MCP servers

| ID | Requirement | Status |
|---|---|---|
| MCP-1 | Servers are configured in Settings ▸ Actions and stored in a Claude/Cursor-compatible `mcp-servers.json` with restricted permissions. Add, edit, enable/disable, Test, Reconnect, Reconnect All, Add Default Servers. | Shipped |
| MCP-2 | Servers are local child processes over stdio. The login-shell `PATH` is resolved so `npx`/`uvx` work from the GUI; absolute paths always work. Per-server environment variables are supported; sensitive-looking keys are stored in the Keychain, never in the JSON file. | Shipped |
| MCP-3 | Two default servers are seeded **disabled**: `chrome-devtools` (`npx -y chrome-devtools-mcp@latest --autoConnect`) and `cua-driver` (`cua-driver mcp`). A guarded migration adds `--autoConnect` only to an unmodified default entry. | Shipped |
| MCP-4 | Only enabled servers contribute tools. Enabled servers connect at app launch, when Actions Mode is switched on, and when their toggle is switched on. | Shipped / In progress (warm connect) |
| MCP-5 | Connection attempts carry ownership tokens; reconnect, cancel, and disconnect invalidate older attempts. | Shipped |
| MCP-6 | Active/current-tab requests bind to exactly one Chrome DevTools connection, withhold native open and Cua routes, and produce a setup error rather than substituting another browser. Naming a non-Chrome browser withholds Chrome DevTools tools. | Shipped |
| MCP-7 | Tool schemas are converted to Foundation Models generation schemas deterministically with cached type names, clipped descriptions (90/140 chars), and nullable handling appropriate to the OS version. | Shipped |

#### 7.10.8 Approval and safety model

| ID | Requirement | Status |
|---|---|---|
| SAF-1 | Every tool call is classified read-only, "changes state" (mutating), or destructive from MCP annotations (`readOnlyHint`, `destructiveHint`) with a conservative name fallback for observation tools. Built-in tools are "changes state". | Shipped |
| SAF-2 | Ordinary UI interactions (`click`, `double_click`, `type_text`, `press_key`, `hotkey`, `scroll`, `drag`, `set_value`, …) are "changes state" even when a server annotates them destructive. Real deletions and `kill_app` stay destructive. | In progress |
| SAF-3 | Three policies: **Only Ask Before Changes** (default: read-only, built-in opens, `type_text`, and ⌘N/⌘T run automatically; other changes ask), **Ask Before Every Tool**, **Just Do It (YOLO)** (read-only and mutating run automatically; destructive still asks). The picker sits under the Actions Mode toggle and on the Actions onboarding step. | Shipped / In progress (name, placement, exemptions) |
| SAF-4 | Destructive tools require approval under every policy. Instant app launch is the only bypass and is limited to opening or activating an installed app the user just named. | Shipped |
| SAF-5 | The menu bar **Auto-Approve Actions** toggle selects Just Do It and, when turned off, restores the asking policy that was active before. | Shipped |
| SAF-6 | Multi-step commands are simulated first; a **plan card** appears only when a predictable native step needs approval. **Approve All** grants exactly the shown native steps (tool plus arguments); **Step by Step** applies the policy per call; **Deny** stops the command. Planned steps are never pre-approved. | Shipped |
| SAF-7 | **Approve Similar** on a "changes state" call that names an app/process lets the same tool run again for the same target during this command; never offered for destructive tools; forgotten when the command ends. | Shipped |
| SAF-8 | Approvals show a concise intent ("Press ⌘S in Notes", "Search the web for “cats” in Helium") with full arguments behind Details; responses are bound to the displayed request; concurrent requests queue FIFO. | Shipped |
| SAF-9 | Limits (defaults, configurable under Advanced where noted): 12 tool calls per command; 120 s per tool; 180 s command deadline excluding queue time; up to 3 queued commands; 40 tools per plan; 64 KB arguments; 1 MB structured results; 4,000 typed characters. | Shipped / In progress (typing) |
| SAF-10 | Cancellation (Escape, deadline, superseding run) denies outstanding approvals, invalidates callbacks, and never rolls back or retries dispatched effects. A cancelled or completed run cannot overwrite a newer run's HUD or state. | Shipped |

#### 7.10.9 HUD

| ID | Requirement | Status |
|---|---|---|
| HUD-1 | A top-centre, non-activating floating pill shows listening, live transcript, early-launch and early-step status, the plan card, approvals, a working card with a live checklist, and a result card. It takes keyboard focus only while a question is pending, then returns focus to the user's app. | Shipped / In progress (session states) |
| HUD-2 | The checklist lists early launches (⚡), numbered steps, each tool call (running, ✓ done, ↩ reused, ✗ failed, ✋ denied), and notes; long runs fold older rows into "… n earlier". It stays on the result card. | Shipped |
| HUD-3 | Successful results auto-dismiss after 8 s (2 s when another command is listening or queued); failures stay until dismissed or replaced. Listening never auto-hides. | Shipped |
| HUD-4 | When another card is showing, a compact "Listening: …" footer displays the next command being heard. Waiting commands appear as "Next: …" rows. | Shipped |
| HUD-5 | Under Just Do It the working card shows a shield and "Just Do It · destructive tools still ask". | Shipped / In progress (label) |

#### 7.10.10 Audit log

| ID | Requirement | Status |
|---|---|---|
| AUD-1 | Every tool call, early launch, early step, plan decision, and approval outcome is appended to `action-audit.log` (on by default) with server, tool, risk, redacted arguments, outcome (`succeeded`, `succeeded (auto-approved)`, `succeeded (pre-approved)`, `speculative`, `failed`, `cancelled`, `denied`, `plan approved/step by step/denied`), and a 500-character redacted detail. | Shipped |
| AUD-2 | Redaction masks sensitive-looking keys (token, password, secret, authorization, cookie, credential, private key, session), UI text/value/label fields, and bearer/key-value secrets inside strings and tool output. `title` and `query` stay readable. Redaction precedes truncation. | Shipped |
| AUD-3 | Entries carry `sinceCommandMs` (from recording start when live text was flowing, else run start) and `durationMs` for the call. Older entries without these fields still decode. | In progress |
| AUD-4 | Speech text is never written to the audit log. Failed structured observations keep their error text. | Shipped / In progress |
| AUD-5 | The log is viewable in Settings ▸ Actions. | Shipped |

#### 7.10.11 Queueing, cancellation, and run ownership

| ID | Requirement | Status |
|---|---|---|
| RUN-1 | Up to three commands wait in arrival order behind the active one; the newest is dropped when the queue is full and the activity log says so. The next command starts immediately when the current one finishes or fails. | Shipped |
| RUN-2 | Each run owns its step budget, result cache, approval grants, deadline, observation binding, and in-flight tasks. Late callbacks from a superseded run are rejected before dispatch. | Shipped |
| RUN-3 | A failed step stops the command; earlier effects stand and the checklist shows what ran. Runtime errors surface via Settings and stay visible until dismissed or a new command starts from idle. | Shipped |

### 7.11 Settings

| Tab | Contents | Status |
|---|---|---|
| General | Usage header (words, WPM, time saved, streak), appearance, launch at login, setup checklist, four shortcut rows with interactive recorders, recording feedback (overlay style, sounds), engine diagnostics | Shipped / In progress (fourth shortcut) |
| Output & Privacy | Filler removal, spoken corrections, auto-paste and clipboard behaviour, history retention, usage-stat retention and reset, last transcript recovery | Shipped |
| Actions (macOS 26 only) | Actions Mode toggle and availability card, approval policy, "Keep listening between commands", Instant App Launch (with recogniser shown), MCP server list with Test/Reconnect/Add Default Servers, Keep Action Log, audit viewer | Shipped / In progress |
| Advanced | Audio input device, phrase replacements (app-scoped), model directory override, idle engine shutdown, Actions step budget, tool timeout, command deadline | Shipped |
| About | Version, engine label (Parakeet TDT 0.6B v3, ONNX), credits | Shipped |

---

## 8. Non-functional requirements

### 8.1 Performance

| ID | Requirement | Current evidence |
|---|---|---|
| PERF-1 | An app named in a command should launch within about 1 s of being spoken. | Measured 1.14 s into a 2.23 s utterance with the default first-unambiguous-partial rule; 2.07 s with a two-partial threshold |
| PERF-2 | Native clauses must never wait on the planner or an MCP connection. | Native router runs before planner; warm MCP connect at launch |
| PERF-3 | App-name resolution must not rescan the disk per lookup. | Memoized inventory; a cold scan measured 0.8 s per open before the fix |
| PERF-4 | Shortcut handling must not be delayed by UI work. | Event tap on its own thread |
| PERF-5 | The first recording's overlay must appear without audio-graph setup on the hot path. | Level-meter engine built once after startup |
| PERF-6 | Pause-to-dispatch latency in a listening session is bounded by the endpoint timer (1 s) plus engine finalisation; safe last clauses run before it (`SpeculativeStepDetector.trailingHold`, 0.7 s). | `ListeningSessionPolicy.endpointSilence` |
| PERF-7 | Every audit entry records `sinceCommandMs` and `durationMs` so latency regressions are visible without instrumentation. | In progress |

### 8.2 Privacy

- No audio, transcript, prompt, or tool result leaves the device. The only network use is the one-time model download and user-configured MCP servers (which are local processes; what they do with the network is theirs).
- History and usage stats are opt-in/aggregate respectively; the app keeps no audio archive.
- MCP secrets live in the Keychain (`com.superkeet.app.mcp`), never in `mcp-servers.json`.
- The audit log is local and redacted; speech text is never logged.

### 8.3 Security

- The release bundle launches only the embedded `parakeet` binary; MCP servers are user-configured local processes.
- Hardened runtime, Developer ID signing, and notarization on release; tag must match `Info.plist` version.
- Invented tool handles are dropped so servers fail closed. Destructive tools always ask.
- Fixed key table for synthetic key events; nothing is posted unless the target app is frontmost.
- Vulnerability reporting per `SECURITY.md` (48-hour acknowledgement, advisory on fix).

### 8.4 Reliability

- Definite outcomes for every recording and every command; no silent loss.
- Bounded engine sessions; independent audio collection; explicit overflow reporting; ≥10 minutes of audio buffered.
- Daemon crash recovery with backoff; readiness-based startup; clean shutdown.
- Run ownership prevents stale callbacks from corrupting newer runs.

### 8.5 Accessibility

- Status changes are announced for assistive technology.
- Reduced-motion is respected in the HUD cursor animation.
- All actions reachable from the menu bar and keyboard (Return/Escape on cards, ⇧Return for Approve Similar).

### 8.6 Compatibility

| Capability | Minimum |
|---|---|
| Dictation | macOS 14.0, Apple Silicon |
| Actions Mode | macOS 26, Apple Intelligence enabled |
| Interim text from engine | parakeet-cli 0.1.7 (protocol 2); protocol 1 engines still work without it |
| Chrome active-tab | Chrome 144+, remote debugging enabled, Node.js for `npx` |
| Cua Driver | 0.28.2+ with Accessibility and Screen Recording granted to CuaDriver |

---

## 9. Technical constraints and architecture

- **Language and toolchain:** Swift 6 language mode, SwiftPM (`swift-tools-version: 6.0`), SwiftUI + AppKit. One dependency: the official MCP Swift SDK (≥ 0.11).
- **Process model:** the app spawns `parakeet serve` (Unix socket JSON) and MCP servers (stdio). Not sandboxed.
- **Layering:** `Models/` are value types and pure decision logic (policies, deciders, routers) with no UI dependencies; `Services/` are singletons owning lifecycle; `Views/` observe services. Pure logic must be unit-tested; stores take an injectable `fileURL`.
- **Conventions (from `AGENTS.md`):** `os.log` only, no `print()`; no force-unwraps or force-casts; main-thread preconditions on UI-touching methods; errors surfaced through `settings.runtimeIssue` or `lastUserFacingError`.
- **Recognisers:** `PartialTranscriptSource` seam selects `DaemonPartialSource` (protocol 2) or `SpeechAnalyzerPartialSource` (macOS 26 fallback); `MicrophoneTapHub` shares one input tap between the meter and the fallback recogniser.
- **Model constraints that shape the design:** text-only input, ~4k-token context, hallucination of opaque identifiers. These drive observation projection, per-step sessions, tool ranking, handle binding, and the deterministic-first routing.

```text
SuperkeetApp (SwiftUI + AppKit)
    ├── MenuBarManager · HotkeyManager (own thread) · RecordingOverlayWindowController
    ├── MicrophoneTapHub ─┬─ AudioLevelMonitor
    │                     └─ SpeechAnalyzerPartialSource (macOS 26 fallback)
    ├── ParakeetService ── bundled `parakeet serve` (Unix socket; protocols 1 & 2)
    │        └── DaemonPartialSource (interim text)
    ├── PasteService · HistoryStore · UsageStatsStore · PhraseReplacementStore
    └── Actions Mode
          ├── ListeningSessionController (session on/off, dispatch on pause)
          ├── SpeculativeLaunchCoordinator (instant launch, early native clauses)
          ├── AgentSessionController (clauses → native / recipe / planner; handoff; queue)
          │     ├── NativeActionExecutor (open_app, open_url, press_shortcut, type_text)
          │     ├── FoundationModelActionPlanner (on-device; per-step sessions)
          │     └── ActionToolRouter → MCPClientManager (stdio servers) · ObservationBinding
          ├── ActionApprovalController (policy, plan card, grants) · ActionHUDWindowController
          └── ActionAuditStore (local, redacted, latency fields)
```

---

## 10. Distribution and release

| ID | Requirement |
|---|---|
| REL-1 | Releases are tagged `vX.Y.Z`; the workflow verifies the tag matches `CFBundleShortVersionString`, builds the pinned `parakeet-cli`, bundles it, signs and notarizes with Developer ID, uploads `Superkeet-<version>.zip` and its SHA-256, and opens a PR against `lucataco/homebrew-tap`. |
| REL-2 | Production releases must be signed and notarized; incomplete secrets fail the release rather than silently falling back. |
| REL-3 | A manual workflow verifies the Homebrew tap token without creating content. |
| REL-4 | Release notes live in `docs/releases/vX.Y.Z.md` and state bundled engine version, validation performed, and known limitations. |
| REL-5 | Local installs (`install.sh`) sign with the first Apple Development / Developer ID identity in the keychain so the Accessibility grant survives reinstalls; `CODESIGN_IDENTITY=-` forces ad-hoc. (In progress) |
| REL-6 | No in-app auto-update; users upgrade via `brew upgrade --cask lucataco/tap/superkeet` or GitHub Releases. |

---

## 11. Quality and verification

- **CI** (`macos-26` runner, on every PR and push to `main`): `swiftlint lint --strict`, `swift build`, `swift build -c release`, `swift test`, `python3 -m unittest discover -s scripts -p 'test_*.py'`. All must pass before merge.
- **Test suite:** 91 XCTest files, 816 tests as of the document date (≈12k lines of tests against ≈19k lines of source). Pure decision logic (hotkey decider, clause splitting, lead-in stripping, intent extraction, native routing, speculative detectors, approval policy, observation binding, listening-session policy, engine cancel policy) is covered by scripted tests, including recorded recogniser output for "open the notes app and create a new note".
- **Audio regression** (`Tests/AudioRegression`): eight synthetic WAV scenarios with an exact critical-word oracle and WER scoring, plus a real-daemon protocol smoke test. Current strict result: 4 of 8 pass (see §13).
- **Live checks not possible in CI:** the Foundation Models call (Apple Intelligence is not enabled on the build host) and real MCP servers. These are verified manually and recorded in release notes.
- **Definition of done for a change:** builds (debug and release), zero lint violations, tests pass, new pure logic has tests, docs updated (`README.md`, `docs/actions-mode.md`) when behaviour changes.

---

## 12. Success metrics (proposed)

The repository does not yet define product metrics. The following are proposed, all measurable locally from the audit log, usage stats, or the regression suite. No telemetry is proposed; these are for the maintainer and for release notes.

| Metric | Source | Target |
|---|---|---|
| Time from app name spoken to launch dispatched | `sinceCommandMs` on `speculative` entries | ≤ 1.2 s median |
| Share of clauses handled natively (no planner) in real sessions | audit outcomes by server (`superkeet` vs MCP) | ≥ 70% of clauses in the maintainer's own logs |
| Repeated actions (a clause executed twice: early and again by the command) | audit log inspection | 0 per session |
| Commands ending in "Nothing to do" that were real commands (false ignores) | manual review of session logs | 0 |
| Dictation completion with a definite outcome | outcome events | 100% (no take without an outcome) |
| Strict audio regression scenarios passing | `scripts/audio_regression.py` | 8 of 8 (currently 4 of 8) |
| Human-recorded accuracy evaluation | new fixture set | Established baseline WER on ≥ 30 real recordings |
| CI green rate on `main` | GitHub Actions | 100% |

---

## 13. Known limitations

1. **No vision.** The on-device model cannot consume screenshots; computer-use servers work through accessibility/element trees only.
2. **Small context.** 4,096 tokens on macOS 26.0 (8,192 measured on a later system). Tool subsets, projected observations, per-step sessions, and overflow continuation mitigate this but complex free-form UI tasks can still overflow.
3. **Acoustic limits.** With synthetic speech, four of eight strict regression scenarios fail: "auth" → "off", "err" → "air", repeated answers, and long-session substitutions. Real-microphone accuracy has not been formally evaluated.
4. **macOS 26 only for Actions.** Dictation works from macOS 14.
5. **User-installed tooling.** Node, Python, Cua Driver, and MCP servers are not bundled; some request their own macOS permissions attributed to their process.
6. **Not sandboxed / not App Store.** By design.
7. **English-centric grammar.** Lead-ins, verbs, recipes, aliases, and TLD lists are English.
8. **Early actions are irreversible.** A launch dispatched while speaking is never undone even if the final transcript disagrees; it is logged instead.
9. **Ad-hoc local signing re-prompts.** Mitigated by identity auto-selection in `install.sh`; still applies when no identity exists.
10. **Sound-alike resolution can surprise.** Bounded to three edits and the same Soundex key, and never used for early actions, but a wrong sound-alike can still open the wrong app after the transcript.

---

## 14. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Apple changes Foundation Models APIs or context limits across macOS 26.x | Planner breaks or degrades | Real token measurement on 26.4+, conservative estimate on 26.0–26.3, overflow retries, `AppleIntelligenceAvailability` gating |
| Engine/app protocol drift | Transcription or interim text breaks | Accept protocols 1 and 2, ignore unknown events, pinned engine tag, protocol smoke test |
| Heuristic grammar mis-splits or mis-routes a command | Wrong app opened, wrong text typed | Deterministic tests for every rule; exact-match-only for early actions; approval for non-exempt steps; audit log |
| A third-party MCP server misbehaves or requests broad permissions | User confusion, unintended actions | Servers disabled by default, risk classification from annotations, destructive always asks, housekeeping tools withheld |
| Model hallucinates identifiers | Server acts on wrong element | Handle binding drops invented values; servers fail closed |
| Listening session perceived as always-on | Trust loss | Explicit shortcut on/off, pill indicator, menu bar state, microphone never open outside a session, documented in Settings |
| Maintainer bandwidth (single maintainer) | Slow response to issues | Strong CI, conventions in `AGENTS.md`, extensive pure-logic tests |

---

## 15. Roadmap candidates and open questions

These are **proposed** and unprioritised. Items 1–3 come from gaps the documentation itself calls out.

1. **Human-recorded accuracy evaluation.** Record real complaint-style samples and microphone variety; make the strict regression suite pass or document acoustic limits precisely. (Docs list this as outstanding.)
2. **Audio retention, replay, and retry.** Explicitly deferred "later recovery phase" in `docs/transcription-preservation.md`. Would need an opt-in, encrypted-at-rest archive and a clear retention policy consistent with §5.1.
3. **Cua Driver / computer-use depth.** More native recipes for common in-app steps (menu navigation, field focus) so fewer steps reach the planner; measure with the native-share metric in §12.
4. **Undo for actions.** Where a native step has an obvious inverse (⌘Z after `type_text`, ⌘W after ⌘N), offer "undo last action" in the listening session. Open question: how to represent irreversible steps honestly.
5. **Per-app command vocabularies.** Let users add recipes ("in Xcode, 'run' means ⌘R") the same way phrase replacements are app-scoped.
6. **Localisation of the command grammar.** Externalise lead-ins, verbs, recipes, and TLDs.
7. **Second-language dictation.** Depends on parakeet-cli model support; out of scope until the engine offers it.
8. **Intel support.** Not planned; revisit only if the engine ships an x86 build and demand appears.
9. **Open question — approval policy naming.** "Just Do It (YOLO)" is deliberately informal. Confirm this is the intended tone for Settings and onboarding.
10. **Open question — listening session default.** It is on by default. Confirm that users upgrading from 1.8.0 should get the new behaviour automatically or be told once in the HUD.
11. **Open question — telemetry.** None exists and none is proposed. If adoption data is ever wanted, it must be opt-in and aggregate, matching the usage-stats precedent.

---

## Appendix A — Defaults and limits

| Setting / limit | Default | Where |
|---|---|---|
| Toggle Recording | ⌥Space | General |
| Push to Talk | fn | General |
| Run an Action | ⌥⇧Space | General (Actions on) |
| Hold to Run an Action | ⌃⇧Space | General (Actions on) |
| Copy to clipboard | Always | — |
| Auto-paste | Off | Output & Privacy |
| Save history | Off; max 1,000 records | Output & Privacy |
| Filler removal | Off | Output & Privacy |
| Spoken corrections | Off | Output & Privacy |
| Overlay style | Mini | General |
| Sound cue | System Cue | General |
| Appearance | System | General |
| Idle engine shutdown | Never (0 min) | Advanced |
| Actions Mode | Off | Actions |
| Approval policy | Only Ask Before Changes | Actions |
| Keep listening between commands | On | Actions |
| Instant App Launch | On | Actions |
| Keep Action Log | On | Actions |
| Endpoint silence (session) | 1 s | code |
| Consecutive failed takes before session ends | 2 | code |
| Step budget | 12 tool calls | Advanced |
| Per-tool timeout | 120 s | Advanced |
| Command deadline | 180 s | Advanced |
| Queued commands | 3 | code |
| Tools per plan | 40 | code |
| Argument size | 64 KB | code |
| Structured result size | 1 MB | code |
| Model-facing result | 800 chars | code |
| Audit detail | 500 chars | code |
| Typed text | 4,000 chars | code |
| App-name words | ≤ 6 | code |
| Fuzzy app match | ≤ 3 edits, same Soundex | code |
| `open_app` window wait | 4 s | code |
| Shortcut/typing activation wait | 1.5 s | code |
| Speculative stability threshold | 1 partial | code |
| Default MCP servers | `chrome-devtools`, `cua-driver` (disabled) | Actions |

## Appendix B — Runtime paths

| What | Where |
|---|---|
| App settings | `UserDefaults` |
| History | `~/Library/Application Support/Superkeet/history.json` |
| Usage stats | `~/Library/Application Support/Superkeet/usage-stats.json` |
| MCP servers | `~/Library/Application Support/Superkeet/mcp-servers.json` |
| MCP secrets | Keychain service `com.superkeet.app.mcp` |
| Action audit log | `~/Library/Application Support/Superkeet/action-audit.log` |
| Bundled engine | `Superkeet.app/Contents/Resources/bin/parakeet` |
| Runtime directory | `~/Library/Caches/com.superkeet.app/Runtime/` (socket, PID file) |
| Model files | `~/Library/Application Support/parakeet/models/parakeet-tdt-0.6b-v3/` |

## Appendix C — Glossary

| Term | Meaning |
|---|---|
| **Take** | One recording from start to a definite outcome |
| **Command Mode** | A take whose transcript is routed to Actions Mode instead of the clipboard |
| **Listening session** | A shortcut-bounded period in which the microphone reopens after each command and utterances dispatch on pauses |
| **Interim / partial text** | Advisory running transcript streamed while recording; never the final text |
| **Instant app launch** | Opening an app the moment its name is unambiguously recognised in interim text |
| **Speculative step / early step** | A native clause executed while the user is still speaking |
| **Handoff** | The early launch and steps passed to the command when the final transcript lands |
| **Clause** | One instruction within a command, as split by `CommandClauses` |
| **Lead-in** | Words around a command that carry no instruction ("hey", "please", "let's") |
| **Recipe** | A deterministic mapping from a spoken step to a shortcut or typed text |
| **Planner** | The on-device Foundation Models session that chooses tool calls for a clause |
| **MCP** | Model Context Protocol; local servers exposing tools over stdio |
| **Risk** | read-only / changes state (mutating) / destructive classification of a tool |
| **Plan card** | The one-time approval for the predictable native steps of a multi-step command |
| **Approve Similar** | A per-command grant for the same "changes state" tool on the same target |
| **Observation binding** | Superkeet's record of pids, window ids, snapshot ids, element tokens, and session labels from the latest observation |
| **HUD** | The floating pill/card that shows listening, approvals, progress, and results |
| **Protocol 1 / 2** | Daemon wire versions; 2 adds interim `partial` events (parakeet-cli 0.1.7) |
