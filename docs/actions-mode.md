# Actions Mode

Actions Mode turns a spoken command into tool actions instead of text. You speak
a task, Superkeet opens apps/URLs natively or plans broader tasks with an
on-device model and local MCP tools. Calls are approved by you or run
automatically according to your approval policy; destructive tools still
require approval.

Actions Mode is **off by default** and completely separate from dictation. A
normal recording still goes straight to the clipboard.

## Requirements

| Requirement | Why |
|---|---|
| macOS 26 | Provides the on-device Foundation Models framework |
| Apple Intelligence enabled | Supplies the on-device language model that plans tool calls |
| MCP servers for additional capabilities | Provide tools beyond the built-in app/URL opening tools |

Actions Mode is offered on its own onboarding step on macOS 26 and can be turned
on later from Settings > Actions. If Apple
Intelligence is turned off, that tab explains how to enable it; on macOS
versions that cannot run it, the tab is hidden and the rest of the app works
normally.

## How it works

```text
Run an Action hotkey (default ⌥⇧Space)
    └── Speech → Parakeet (local, unchanged)
            └── AgentSessionController
                    ├── NativeActionExecutor → simple app/URL opens via NSWorkspace
                    ├── MCPClientManager   → local MCP server processes (stdio)
                    ├── On-device model    → plans tool calls
                    ├── ActionApprovalController → confirmations required by policy
                    └── ActionAuditStore   → local, redacted log
```

1. Press the **Run an Action** shortcut (⌥⇧Space) once to start listening. The
   HUD pill reads **Go ahead, I’m listening.** Speak a command; when you pause
   for about a second it runs, and the microphone reopens for the next one. Press
   the shortcut again (or Escape) to stop listening; the microphone is off
   whenever the pill is gone. This is the **listening session** (Settings ▸
   Actions ▸ *Keep listening between commands*, on by default). With it off, the
   shortcut records one take: press to start, press again to run. **Hold to Run
   an Action** (⌃⇧Space) always records one take while held.
2. The HUD displays live words while you speak, and native clauses run as soon
   as the next clause begins (see “Native clauses while speaking”). After you
   pause or stop, Superkeet uses Parakeet's final transcript, applies your
   phrase replacements, drops filler (“Great. Okay, thanks.” runs nothing), and
   recognises what already ran. Simple app/URL/typing commands run directly;
   broader requests use the on-device planner.
3. Each tool call is classified as read-only, mutating, or destructive. The
   default policy runs read-only tools and built-in app/URL opens automatically;
   other state-changing calls ask in the floating HUD. Multi-step commands show
   a **plan card** when a predictable step needs approval (see “Approving a whole
   plan” below). The HUD then shows a checklist and the command's result.
4. Approved or auto-approved calls run through the native executor or MCP
   server. Planned tool results are truncated and fed back to the model until
   the task is done.
5. Press plain **Escape** once to stop an action and clear its waiting commands.
   During Actions Mode, the event also reaches the focused app, so its normal
   Escape behavior still applies. Modifier combinations and autorepeat do not
   cancel a later action. Escape remains a consumed shortcut when only a speech
   recording is active.

### Built-in app and URL opening

These literal commands use native macOS APIs without a shell server, MCP
connection, or planner call:

- `open discord`
- `let's open Helium browser` (lead-ins such as “let's”, “please”, “can you”,
  “I want to” are ignored; “pull up”, “fire up”, “start”, “show me” also open)
- `switch to Notes` (opening a running app brings it forward and restores
  minimized windows)
- `open Helium and go to youtube.com`
- `go to youtube.com in Helium`
- `open youtube.com` (uses the default browser)
- `search for Morgan Freeman` / `google Morgan Freeman` / `look up …` (opens a
  web search in the default browser, the browser you name with a trailing “in
  Chrome”, or the browser an earlier step opened)

Superkeet resolves registered bundle identifiers for known names/aliases, then
matches installed app names case-insensitively in `/Applications`,
`~/Applications`, and `/System/Applications` (including Utilities). Trailing
“app”/“browser” and punctuation are ignored for app-name matching; aliases such
as “Chrome” resolve to Google Chrome, and everyday names (“the camera” for Photo
Booth, “email” for Mail, “settings” for System Settings, “calc”) are aliases too.

Lookups go through the memoized inventory scan; a fresh directory scan per open
used to cost 0.8 s, most visibly on every miss. A name of more than six words is
refused before the disk is touched, since it is the rest of the sentence, not an
app. When nothing matches exactly, the command that runs after the transcript
accepts a sound-alike within three edits and the same Soundex key (“the crown”
opens Google Chrome, “nodes” opens Notes); partial names (“Heli”) do not
qualify, and nothing launched while the user is still speaking ever rides on a
guess. Spoken addresses are joined before URL detection: “X dot com” is `x.com`
and “youtube dot com slash trending” is `youtube.com/trending`, but only real
endings join, so “polka dot dress” stays words.

The built-in `open_app {name}` and `open_url {url, browser?}` tools **run without
an approval prompt under the default “Only Ask Before Changes” policy**. “Ask
Before Every Tool” still asks for these calls. Their risk remains “changes
state”, and automatically approved opens are logged as
`succeeded (auto-approved)`. They share MCP calls' approval routing, timeout, step budget,
and audit log; this exemption applies only to these two built-in tools.

Compound requests such as `open Helium and summarize the page` run the open natively
and use the planner for the remaining task, with the compact built-in tools
available first. `open Chrome and search for Morgan Freeman` needs no planner at
all: both steps are native. Open targets are resolved, including sound-alikes,
before launching. An unresolved name uses a Google “I'm Feeling Lucky” URL;
`open the Hacker News website` is one native URL open. If a current or carried
app exists, an unresolved target such as `open Saved Messages` goes straight to
the planner with that app as context. An explicit `website`, `site`, or `page`
suffix still selects the web. Leading `new`, `my`, and `that` are ignored when
resolving app names, and `open up Helium and go to youtube.com` uses the same
native route as `open Helium and go to youtube.com`.
Denial, cancellation, timeout, and launch failure
stop the command rather than retrying an open operation.

`open_app` waits up to four seconds for the app to finish launching and show an
ordinary window, then reports `Opened Notes (pid 1234, com.apple.Notes). Its
window is on screen.` (or `No window has appeared yet.`). An app that is already
running is unhidden, its minimized windows are restored through Accessibility,
and it is activated, so “open Chrome” always ends with Chrome in front. Apps
launched early while you were speaking are not waited on; a later step that acts
inside the app waits for its window first, while a URL or search step does not. The pid and bundle
identifier let later steps target the app without a discovery round-trip, and
the planner learns whether there is anything to observe yet. Apps that
legitimately open without a window are reported, not failed.

A compound request whose clauses include an app or URL open, or a keyboard
shortcut step (below), still runs with the built-in tools when no MCP server is
enabled or no MCP tools are available. Requests that need neither keep the
**“No MCP servers are enabled”** setup hint.

### Built-in keyboard shortcuts

The third built-in tool, `press_shortcut {app, keys}`, presses a key chord such
as `["cmd", "n"]` in a running app: Superkeet activates the app, waits until
macOS reports it frontmost (up to 1.5 s), and only then posts the key events —
the same path automatic paste uses for ⌘V. Nothing is sent if the app is not
running or does not come to the front, and the key table is fixed (letters,
digits, return, tab, space, delete, escape, arrows, F-keys, with cmd/shift/
option/control). ⌘N and ⌘T only create something new, so like app/URL opens
they run without asking under the default policy. Every other chord requires
approval under the default policy, with an intent such as `Press ⌘S in Notes`.
“Just Do It (YOLO)” runs all of them automatically because they are classified
as mutating, not destructive.

Common verbs never reach the model. `NativeAppRecipe` maps them straight to
the standard shortcut for the app the step refers to:

| Spoken step | Shortcut |
|---|---|
| create / make / start / compose / write / add / open a new ‹thing› | ⌘N (⌘T for a new tab) |
| save (it / the document) | ⌘S |
| close (it / the window / the tab) | ⌘W |
| undo / redo | ⌘Z / ⇧⌘Z |
| select all | ⌘A |
| quit (‹app›) | ⌘Q |

A trailing “in ‹app›” names the target; otherwise the step goes to the app the
command most recently opened. A named app must be installed and running, and a
step with no target app is left to the planner. The planner can also call
`press_shortcut` itself for phrasings the table does not know; in a live check
with Notes already open, the on-device model answered “create a new note” with
exactly one ⌘N in Notes.

### Built-in typing

The fourth built-in tool, `type_text {app, text}`, types dictated words into a
running app at its insertion point with synthetic Unicode key events (the same
path automatic paste uses), in 20-character chunks with a Return press per new
line. Like `open_app`, it runs **without asking under the default policy**: the
user just dictated the words and named the app. `NativeTypeRecipe` maps the
common phrasings straight to it, so “make the title say hello” never reaches
the model:

| Spoken step | Typed |
|---|---|
| type / write / enter / put / insert ‹text› | ‹text› |
| make the title (heading, note, it) say ‹text› | ‹text› |
| set the title (heading, name) to ‹text› | ‹text› |
| name it / title it / call it ‹text› | ‹text› |

Surrounding quotes and a sentence-final period are removed; other punctuation
is kept. A trailing “in Notes” names the target app; when the trailing name is
not a running app (“into Body”, “in Paris”) it is part of the text and the
current app takes the full phrase. With nothing opened by the command yet, the
frontmost app is the target. “write a new note” is ⌘N, never typed text.

## Multi-step commands

`CommandDecomposer` splits a command at `and then`, `then`, semicolons and
newlines, and at `and`, a comma, or a sentence end (`.`, `?`, `!` followed by a
space) **when a new instruction follows** (a known verb such as open, search,
click, type, create, save, or a web address) **or when only filler follows**.
Parakeet punctuates, so “Open Discord. Open Notes.” is two steps, while
`search for Dr. Smith`, `youtube.com` and `3.5` stay whole. `search for Morgan
Freeman and Tom Hanks` and `type milk, eggs and bread into Body` therefore stay
one step, quoted text is never split, and each part is classified on its own.

Three kinds of clause carry no instruction and are dropped rather than sent to
the planner (`CommandLeadIn`): acknowledgements (“Great. Great. Okay, let's move
on.”, “Cool. Awesome. Thank you.”), bare connectors (“and once you're there”),
and short context phrases that open with a preposition and contain no
instruction verb (“inside this new note”, “in the Notes app”). An utterance made
only of such words is ignored entirely with the outcome **Nothing to do**.
Trailing politeness (“for me”, “please”, “thanks”, “ah”) is stripped from app
names and search queries but never from text to be typed, and connectors
(“and”, “also”, “then”, “next”, “once you're there”) count as lead-ins, so “And
once you're there, can you create a new note?” is exactly “create a new note”.
“Google search X”, “search up X” and “search Google for X” are searches for X.
Active-tab requests are never split. A single-step command behaves exactly as before.

Each step is then carried out in order, trying the cheapest route first:

1. **Already done.** If an app launched while the user was speaking
   (Instant App Launch) and the step just names that app, it is skipped.
2. **Native open.** `open ‹app›` / `go to ‹url›` run through the built-in tools.
   A URL step with no browser uses the browser an earlier step opened.
3. **Shortcut recipe.** See the table above.
4. **Planner.** Everything else goes to the on-device model in a **fresh
   session per step**, with `ActionPlanContext` appended to its instructions:
   the full command, which step this is, what earlier steps did, and which apps
   are already open (“Notes is already open (pid 1234; its window is on screen).
   Do not open it again; act inside it.”). Per-step sessions keep each prompt
   small, and the model's `open_app` call for an app that is already open is
   satisfied from the run instead of relaunching.

The recognised single open `open ‹browser› and go to ‹url›` still runs as one
native step before any decomposition, so the browser and URL are never split.
A step that fails (denial, timeout, launch error) stops the command; earlier
effects stand and the HUD lists “Step 2 of 3: …” lines for what ran.

### Approving a whole plan

Choose an approval policy in **Settings ▸ Actions ▸ Safety ▸ Approval**:

- **Only Ask Before Changes** (default) runs read-only tools, the built-in
  `open_app` / `open_url` tools, and the ⌘N / ⌘T shortcuts automatically. Other
  mutating and destructive tools require approval.
- **Ask Before Every Tool** requires approval for every tool call, including
  read-only tools and the built-in opening tools.
- **Just Do It (YOLO)** runs read-only and mutating tools automatically.
  **Destructive tools still require approval.** A plan of app opens and keyboard
  shortcuts therefore runs without a plan card.

The picker sits directly under the Actions Mode toggle in Settings ▸ Actions and
on the Actions step of onboarding. The menu-bar **Auto-Approve Actions** item
turns “Just Do It” on. Turning it off restores whichever asking policy was active
before (“Only Ask Before Changes” or “Ask Before Every Tool”), falling back to
“Only Ask Before Changes” when the policy was chosen in Settings. While “Just Do
It” is active, the working card shows a shield and “Just Do It · destructive
tools still ask”. State-changing calls that
skip approval are logged as `succeeded (auto-approved)`; read-only calls that
skip approval retain the plain `succeeded` outcome.

Before a multi-step command runs, Superkeet simulates it — the same
routing that will execute it, with opens assumed to succeed so later steps know
which app they act in — and shows one **plan card** if a predictable native step
requires approval. Under the default policy, “open Notes and create a new note”
runs without a card (⌘N is exempt, like the open); “open Notes and save it” asks
because of ⌘S:

```text
Approve this plan?          “open the notes app and save it”
  1. Already open: Notes (opened while you were speaking)
  2. Press ⌘S in Notes                                   Changes state
                              [Deny]      [Step by Step]  [Approve All]
```

- **Approve All** (Return) grants exactly the shown native steps — tool plus
  arguments — for this command. Different calls that come up later follow the
  selected policy. Steps marked *Planned* use the on-device model; their tool
  calls were not shown, so each goes through the policy individually.
- **Step by Step** runs the plan using the selected approval policy for each
  call instead of pre-approving the native steps. Read-only calls and exempt
  opens still run automatically under the default policy.
- **Deny** (Escape) stops the command: “The plan was not approved, so no further
  steps ran.” An app that opened while you were speaking stays open.

An open-only plan skips the card under the default policy, and adding a
`press_shortcut` step other than ⌘N / ⌘T makes it ask. Under “Just Do It”, only a
predictable destructive step requires a plan card. A plan made only of model-driven steps
runs straight away, since the card could not pre-approve anything; its later
tool calls still follow the policy. Single-step commands never show a plan
card. Plan decisions are written to the action log as
`plan approved`, `plan step by step`, or `plan denied` with the step summaries.

### Approve similar

A tool-call approval offers **Approve Similar** (⇧Return) when the call is
“changes state” (never destructive) and names an app or process — `app`,
`browser`, `pid`, `bundle_id`, or a browser page id. It approves the call and
lets the same tool run again for the same target during this command without
asking, so a model that clicks three controls in Notes asks once. Grants are
forgotten when the command ends. Calls that ran under a grant are logged as
`succeeded (pre-approved)`.

### Chaining commands

Inside a listening session no key is needed: each pause hands the utterance to
the runner and the microphone reopens as soon as the engine is idle again, so
the next command can be spoken while the previous one still runs. Utterances
queue in arrival order like any other command. `ListeningSessionController`
owns the session: a pause is interim text unchanged for
`ListeningSessionPolicy.endpointSilence` (1 s; the engine emits a partial every
0.5 s of speech, and on a long take it keeps re-decoding words already heard, so
only an ending of the transcript not yet seen in the take counts as new speech);
the engine returning to
idle reopens the microphone; two failed takes in a row, the engine stopping,
Escape, or the shortcut end the session. One start sound plays when the session
opens and one stop sound when it closes; nothing plays per utterance, and the
recording overlay stays hidden because the HUD pill is the indicator.

The app a command ended up acting in carries over to the next utterance of the
same session (`AgentSessionController.carriedApp`), so “type hello” spoken on
its own after “open Notes” types into Notes natively, and a clause that names no
app starts from it while the user is still speaking. A named app in the next
utterance replaces it, an app that has since quit is ignored, and the carried
app is forgotten when the session ends.

With the session setting off, press **⌥⇧Space** while a command is planning,
running, or waiting for approval to record the next command; press it again to
finish that recording. Completed
commands queue in arrival order, with up to **three waiting commands** in
addition to the active one. If the queue is full, the newest command is dropped
and the activity log notes which command was skipped.

The next command starts immediately when the current one finishes or fails.
Each command gets its own approval grants, result cache, step budget, and
deadline; time spent waiting does not count toward that deadline. Errors remain
visible in Settings, and tool outcomes remain in the action log. The working
and result cards show waiting commands as **Next: “open Notes”** rows.

**Escape** stops the active run, cancels a next command still being recorded or
transcribed, and clears the queue. Instant App Launch can still open an app
while you speak a queued command; that command reuses its early launch when it
starts. Start and stop each recording with the shortcut — listening is not
automatically re-armed after a command.

### The checklist

While a command runs, the HUD lists what is happening as rows whose status
changes in place: an app that opened while you were speaking (⚡), each step of
a multi-step command with its number, every tool call (running, ✓ done, ↩
reused, ✗ failed, ✋ denied), and notes such as “Using ⌘N to create a new note
in Notes”. Long runs fold older rows into “… n earlier” and keep the current
step visible. The checklist stays on the result card so you can see what ran.

The HUD is a non-activating panel: it only takes keyboard focus while a plan
card or approval is showing (so Return and Escape work), and hands focus back
to the app you were working in as soon as you answer.

If a planned step's transcript overflows the model's context **after** tools
have run, the step is not lost: `ActionProgressSummary` condenses the calls
made so far (tool, clipped arguments, clipped result, outcome) and the planner
continues once in a fresh session that is told not to repeat them. Overflow
before any tool ran still retries with a smaller tool set, as before.

### Live transcript in the HUD

During a listening session one pill stays up from the first press to the last:
**Listening** with **Go ahead, I’m listening.** while idle, the live words while
you speak, the early launch and any clause that ran early beneath them
(**Press ⌘N in Notes…**, then **Pressed ⌘N in Notes**), the working and result
cards while a command runs, and back to the prompt. Its subtitle shows the
shortcut that stops the session and how many commands have run. A **Stop**
button does the same as Escape.

The **Listening…** card shows the words as they are recognised, up to three
lines, with a blinking **▍** cursor while recording. It starts with
**Say a command…** until the first words arrive. After you stop recording, the title
becomes **Transcribing…** and the last live text stays visible until the final
transcript arrives. An early app launch appears as a one-line **Opening Notes…**
or **Opened Notes** status beneath the words.

If an approval, plan, working, or outcome card is already showing, a compact
**Listening: …** footer displays the next command being heard. Live text works
with Instant App Launch turned off, using either Parakeet's interim text or the
Apple speech fallback. When no action is running, the menu bar also shows
**Listening…** with a blue waveform icon.

Listening does not take keyboard focus and never auto-hides. A completed
command's result normally hides after eight seconds; this drops to two seconds
while another command is listening or queued. If listening is active, only the
completed-result card is dismissed, revealing the live transcript underneath.
Partial-text updates do not restart that timer. Failure cards stay until
dismissed or replaced by the next command.

### Compact observations

Computer-use observations are far too large for the model: a real
`get_window_state` for Notes is 185 KB of JSON (363 elements, ~100 menu items,
the whole note body). Truncating that to 800 characters used to discard every
useful control. Instead, `ObservationProjection` renders the structured result
as ranked lines such as `[184] Button “New Note”` and `[290] MenuItem File ▸
“New Note”`: labeled, actionable elements only, ordered by how many of the
step's words they match, menu items shown only when they match, internal
identifiers dropped, and text bodies reported as `(7897 characters)` rather
than quoted. `list_windows` and `list_apps` are condensed the same way.
Superkeet also asks these observations for the element tree only
(`include_screenshot: false`) unless the model explicitly asked for a
screenshot, since it cannot see images.

Command Mode uses **phrase replacements only**, so a rule such as
`categolabs → catacolabs` can correct a spoken domain. Its app-scoped rules use the
app active when recording started. Filler removal and dictation's spoken-editing
commands do not alter command arguments. An incomplete/partial command shows a
retry error and never enters the clipboard/paste path.

### Live command recognition

Historically Parakeet returned text only after a recording stopped, so nothing
could react while you were still speaking. The live HUD and Instant App Launch
use interim text, which Superkeet takes from one of two recognisers behind the
`PartialTranscriptSource` seam, chosen per recording by `PreferredPartialSource`:

1. **The Parakeet engine itself** (`DaemonPartialSource`), when the running
   daemon speaks protocol 2 (parakeet-cli 0.1.7+). A Command Mode recording
   sends `{"command":"start", …, "partials":true}` and the daemon streams
   `{"type":"partial","text":…,"sequence":n,"truncated":…}` events roughly
   every 0.5 s of captured audio (v0.1.9; 0.75 s in v0.1.7–0.1.8), each with the
`audio_ms` it covers. One model produces both the interim and the
   final text; there is no second microphone consumer, no second speech model,
   and it works on every macOS version Superkeet supports. Command Mode requests
   partials whenever Actions Mode is enabled and an interim source is available,
   even with Instant App Launch off. Ordinary dictation does not request them.
2. **Apple's on-device `SpeechAnalyzer`** (`SpeechAnalyzerPartialSource`, macOS
   26) as the fallback while the daemon is not running yet or is a protocol-1
   engine. `MicrophoneTapHub` owns one `AVAudioEngine` input tap that the
   overlay meter and this recogniser share. Volatile results with the fast
   preset recognise an app name about one second into the sentence; installed
   app names are supplied as contextual strings; speech assets are reserved per
   app and a download is only offered, never started automatically.

Both deliver cumulative `PartialTranscript` values (running text, a final flag,
a sequence number) to `SpeculativeLaunchCoordinator`. It publishes the live text
for the HUD and passes it to the detector only while Instant App Launch is
enabled. The final transcript always comes from Parakeet's `complete` event.
Settings ▸ Actions ▸ Instant App Launch shows which recogniser the next recording
would use.

Interim text from the engine is advisory: it is decoded from audio no committed
segment owns yet, with 0.3 s of silence appended so the decoder finishes the
last word instead of inventing a tail. A partial's final word may change in the
next one; the detector's ambiguity rule (wait while another installed name
extends the spoken one) exists for exactly this. Superkeet accepts daemon protocols
1 and 2 and ignores event types it does not know, so engine and app releases
need not be lock-stepped.

#### Deciding what may run early

`SpeculativeIntentDetector` reads the running text and decides, at most once per
recording, that an app should open or come forward before the sentence ends.
It is plain string handling over the installed-app inventory, so every rule
below is covered by scripted tests, including the recogniser's recorded output
for “open the notes app and create a new note”.

- Lead-in words (“hey”, “please”, “um”, “can you”, “let's”, “I want to”, “go
  ahead and”, “superkeet”, …) are skipped by `CommandLeadIn`, the same list the
  intent extractor uses, so the launch and the command agree on where the verb
  starts. The clause must then start with `open`/`open up`/`launch`/`pull up`/
  `fire up`/`start`/`show me` (a launch) or `switch to`/`switch over to`/
  `activate`/`bring up`/`go to` (an activation).
- The app reference runs from the verb to the first clause boundary (`and`,
  `and then`, `then`, `to`, `so`, a comma/semicolon/colon, or a sentence-ending
  period) and resolves through the same `AppResolver` as `open_app`, so “the
  Notes app” and aliases such as “Chrome” work. Conjunctions inside names
  (“Android Studio”) are not boundaries.
- A launch commits when any of these holds: a boundary followed the name; the
  name resolved to an installed app **and** no other installed name extends the
  spoken one (“Safari” waits while “Safari Technology Preview” is installed,
  “Note” waits while “Notes” is); or the recogniser finalized the text. The
  first unambiguous sighting is trusted (`stabilityThreshold` defaults to 1); a
  higher threshold demands that many consecutive partials name the same app.
- An activation additionally requires the app to be running. Switching to a
  stopped app is left to the real command.
- Nothing commits when the clause contains a web address (that is a URL open),
  when the command carries an active/current-tab scope, or when the name does
  not resolve to an installed app. A misheard name therefore does nothing.
- The decision is never undone. If later text names a different app, or the
  finalized text no longer names the committed one, `disagreement` is recorded
  so the result can say the app was opened early.

Installed-app lookups come from `InstalledAppInventory`, which scans the
application directories once on a background task (hundreds of milliseconds)
and answers later lookups from memory. Until the first scan finishes, nothing
resolves and nothing speculative runs.

#### Instant app launch

**Settings ▸ Actions ▸ Instant App Launch** (on by default when Actions Mode is
on) turns the detector's decision into an action. It is separate from the tool
approval policy: when enabled, early launches happen directly and reusing them
does not ask again. `SpeculativeLaunchCoordinator` listens from the moment a
Command Mode recording starts:

1. `ParakeetService.startRecording` calls `begin(sessionID:)` when Command Mode
   is armed. The coordinator starts the interim-text source and creates a
   detector for that session, publishing live text whether or not instant
   launches are enabled.
2. When the detector commits, the app opens through `NativeActionExecutor`
   directly — **without the approval HUD**. This bypass is limited to opening or
   activating an installed app that the user just named. The regular `open_app`
   tool keeps its “changes state” risk and follows the selected policy, including
   its no-prompt exemption under the default policy. The HUD shows “Opening
   Notes…”, then “Opened Notes”, beneath the live words while the recording
   overlay stays up.
3. Every early launch is written to the action log with outcome `speculative`
   (or `failed`), the reason the detector committed, and the partial's sequence
   number. Speech text is not logged.
4. When the final transcript arrives, `take(sessionID:)` stops listening and
   hands the launch to `AgentSessionController`, which waits for macOS to
   report the launch, adds “Opened Notes while you were speaking” to the
   activity log, and satisfies any later `open_app` call that resolves to the
   same bundle from that launch instead of opening the app again. “Open the
   Notes app” therefore finishes with no approval and no second launch; “open
   the Notes app and create a new note” plans the second clause with Notes
   already open.
5. Cancelling or failing the recording calls `end(sessionID:)`: listening stops
   and nothing is handed over. A launch already dispatched to macOS is left to
   finish and is still audited; it is never undone.

Measured with the recorded recogniser output for “open the notes app and create
a new note” (2.23 s of speech), Notes launches about 1.14 s in with the default
of trusting the first unambiguous partial, or about 2.07 s in when two
consecutive partials are required (`SpeculativeLaunchCoordinator(stabilityThreshold:)`).
The early launch does not wait for the app's window, so the command starts the
moment the transcript lands.

If the final transcript names a different app than the one launched, the
launched app stays open, the command opens the app it actually asked for, and
the activity log notes the disagreement.

#### Native clauses while speaking

The launch is only the first clause. `SpeculativeStepDetector` reads the same
interim text and runs every later clause that `NativeClauseRouter` can carry out
natively (an app or URL open, a web search, a ⌘N-style shortcut recipe, or a
`type_text` recipe) as soon as the **next clause has begun**, that is, once a
separator and a new instruction follow it, or the text ends in “and” / “then”.
Steps run strictly in order after the launch; a step inside a freshly launched
app waits for its window first.

**The last clause** is still being spoken, so it runs early only when that is
safe and it has settled: an app open (unless a longer installed name could still
be coming, as with “Safari” / “Safari Technology Preview”), a URL, a shortcut
recipe (⌘N, ⌘T, Photo Booth's shutter), or a web search once the recogniser has
punctuated the end of the sentence. It must map to the same action on two
partials in a row, or stay unchanged for `SpeculativeStepDetector.trailingHold`
(0.7 s, longer than the engine's 0.5 s partial cadence) with no newer partial.
Typing never runs before the speaker moves on, so half-heard words are never
typed. So “open the Notes app and create a new note” presses ⌘N while the
speaker is still finishing the sentence, with no pause and no final transcript.

A clause that needs the planner stops early execution at that point, since every
later step would change the frontmost app or its contents under it. The stop is
re-evaluated on every partial, so when the recogniser corrects a garbled word the
detector carries on. Clauses that already ran are re-checked against each new
partial; if a finished clause now means something else, positions can no longer
be trusted and early execution stops for the rest of the take.

Routing reads through conversational phrasing and recogniser glitches. A clause
is tried as spoken, then without lead-ins (“can you create a new note”), then
from a mid-clause request (“umce right there can you create a new note”), and,
for opens only, without a glued-on reaction (“open up x.com Nice”). The splitter
likewise starts a new clause at a request that follows a few context or garbled
words (“… and inside this new note let's make the title say hello”).

Opens and URLs run early under the same Instant App Launch toggle as the
launch; shortcuts and typing run early only when the approval policy would not
have asked about them anyway (⌘N, ⌘T and `type_text` under the default policy;
everything mutating under Just Do It; nothing under Ask Before Every Tool).
Each early step is written to the action log with outcome `speculative` and the
clause number.

For “open the Notes app and create a new note and make the title say hello and
open Safari”, Notes launches at “and”, ⌘N is pressed when “and make” arrives,
“hello” is typed when “and open” arrives, and only “open Safari” waits for the
pause, or, being an open, until it has held still. When the final transcript lands, `SpeculativeHandoff` carries the launch
and the steps to `AgentSessionController`, which waits for them, lists what ran
(“Pressed ⌘N in Notes while you were speaking”), and marks the matching clauses
**Already done** instead of repeating them: matched by the action the final
clause maps to, then by its words, then, for steps inside an app, by position
and tool, because repeating a shortcut or typed text would do it twice. A step
that failed early is simply done again by the command.

## Configuring MCP servers

Servers are configured in **Settings ▸ Actions**. The on-disk file is
Claude/Cursor compatible:

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["-y", "chrome-devtools-mcp@latest", "--autoConnect"]
    }
  }
}
```

Stored at `~/Library/Application Support/Superkeet/mcp-servers.json` with
restricted permissions.

Only **enabled** servers contribute tools to a plan. Enabled servers are
connected when the app launches, when Actions Mode is switched on, and when a
server's toggle is switched on, so a cold `npx` start is not on the first
command's critical path. **Test** and **Reconnect** can establish diagnostic
connections, but a connected server with its toggle off is excluded. If a request needs planning and no MCP servers are enabled, the HUD
shows **“No MCP servers are enabled”** with a Settings hint. The deterministic
native app/URL fast path runs before this check, and compound requests that
contain an open clause plan with the built-in open tools instead of failing.

### Result reuse and live observations

Within one command, an identical tool call (same tool, same arguments) reuses
its earlier result instead of running again. Two rules keep that cache honest:

- Read-only tools that describe live state — Cua Driver's `list_apps`,
  `list_windows`, `get_window_state`, `get_accessibility_tree`, `verify_state`,
  `get_browser_state`, Chrome DevTools' `list_pages`, `take_snapshot`,
  `evaluate_script`, and any read-only tool named `list_*`, `get_*`, `take_*`,
  `verify_*`, or containing `snapshot`/`screenshot` — always run fresh, because
  apps, windows, and pages change between calls without any Superkeet action.
- Every successful state-changing tool drops all cached read-only results, so an
  observation taken before a click is never served after it. Mutation results
  stay cached: an identical mutation is reused, never repeated.

### Planner tool selection

The planner ranks the complete enabled inventory by intent before applying the
40-tool cap and context budget. App opening favors `launch_app`, window
activation, and app discovery; URL tasks favor navigation/page tools; clicks and
screen-reading favor accessibility observations. Common description words such
as “open”, “and”, “the”, and “com” do not inflate relevance. Equal scores use
stable tie-breaks, and round-robin ordering keeps enabled servers represented.

Each tool bridge caches its parameter schema. Object/enum type names are derived
deterministically from the tool namespace and property path. Parameter
descriptions retain up to 90 characters, while the tool summary is capped at
140 characters. The fallback token estimate uses these same clipped descriptions
and schema shapes; macOS 26.4+ measures the framework's actual token cost.
Nullable type arrays preserve the underlying scalar/object/array type; 26.4+
also represents explicit null, while 26.0–26.3 generate the permitted non-null
type without dropping required fields.

### Default servers

Superkeet seeds two servers the first time it runs (both **disabled** until you
enable them, so nothing launches unexpectedly):

| Server | Command | Purpose |
|---|---|---|
| `chrome-devtools` | `npx -y chrome-devtools-mcp@latest --autoConnect` | Attach to a running Chrome profile and inspect its existing tabs |
| `cua-driver` | `cua-driver mcp` | Background computer use from [Cua Driver](https://cua.ai/docs/cua-driver): drives native apps and browsers without stealing focus |

If you remove one, use **Add Default Servers** in Settings ▸ Actions to restore
it. Enabling a server makes Superkeet launch and connect to it whenever an action
runs. The default Chrome DevTools configuration connects to Chrome after the
setup below. Cua Driver needs Screen Recording and Accessibility access, so
enable each server when you need it.

#### Active Chrome tab setup

1. Install Node.js LTS/npm and use **Chrome 144 or newer**.
2. Start Chrome and open `chrome://inspect/#remote-debugging`. Enable remote
   debugging using that page's toggle. This is a one-time Chrome setup step.
3. In **Settings ▸ Actions**, enable **chrome-devtools**. Use **Reconnect** after
   editing its configuration. When Chrome asks to allow the incoming debugging
   connection, choose **Allow**. The dialog may appear on the first browser tool
   call; **Test** alone checks the MCP handshake, not page access.
4. Focus the target tab's page content before issuing an active-tab command.

`--autoConnect` requires Chrome to be running. With multiple active profiles,
Chrome determines the default profile used by the connection; the server sees
that profile's open windows/tabs. Make sure the desired tab and its logged-in
Cloudflare session are in the connected profile. See Chrome DevTools MCP's
[running-Chrome setup guide](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/main/docs/advanced-usage.md#automatically-connecting-to-a-running-chrome-instance).

On configuration load, Superkeet appends `--autoConnect` to an existing
`chrome-devtools` entry only when it still has the original `npx` command and
exact arguments `["-y", "chrome-devtools-mcp@latest"]`, an empty environment,
and no extra custom entry fields. The migration preserves its enabled flag and
the other JSON entries/fields. Custom commands, pinned versions, profiles,
endpoints, environment settings (including Keychain values), and renamed entries
are excluded. For a custom entry, add `--autoConnect` explicitly when choosing
the running-profile connection mode. A failed migration reports a settings error
and retains the loaded configuration and original file.

#### Active-tab commands and Cloudflare DNS

Examples:

- `In the current Chrome tab, go to youtube.com`
- `Find the DNS records in the active tab`
- `In the active Chrome tab, open Cloudflare DNS for catacolabs.com`

The explicit active/current-tab qualifier is recognized before the native open
fast path. It produces a `navigate` or `find` intent scoped to an existing Chrome
tab. Those requests use one Chrome DevTools server, prioritizing `list_pages`,
focus inspection, `navigate_page`, `take_snapshot`, and `click`. Native open
tools, `new_page`, and Cua routes are withheld for this scope. An explicitly named
non-Chrome tab, missing Chrome tools, or multiple eligible Chrome connections
produces a setup error instead of substituting another browser.

The planner is told to get page IDs from `list_pages`. MCP's **[selected]** marker
describes its tool context and may initially be the first page; it is not proof
of the user's active tab. With multiple pages, the guidance requires focus
evidence (`document.hasFocus()` through `evaluate_script`) before choosing a
page. If the available results cannot identify it unambiguously, the planner is
instructed to explain the limitation and stop. Subsequent calls retain the
observed `pageId` (or use `select_page` without bringing a tab to the front on
older selected-page-only servers). Page lists and snapshots bypass the result
cache so later observations reflect navigation and page changes.

For Cloudflare DNS navigation, the planner receives this dashboard template:

```text
https://dash.cloudflare.com/?to=/:account/<zone>/dns/records
```

For the example zone, that is
`https://dash.cloudflare.com/?to=/:account/catacolabs.com/dns/records`. The zone
must come from the command or verified tool output; unclear/misheard domains
require clarification or a phrase replacement rather than a guessed spelling.
Cloudflare may require login or account/zone selection. Its official
[DNS Records guide](https://developers.cloudflare.com/dns/manage-dns-records/how-to/create-dns-records/)
also supplies the generic `:account/:zone` dashboard selector link.

The deep-link plus `navigate_page` route avoids searching for dashboard controls
in a long accessibility snapshot. Free-form Cloudflare UI interaction still has
the on-device model's 4,096-token context and 800-character tool-result/snapshot
limit. Successful navigation alone is not evidence that records were read or
changed.

#### Cua Driver notes

- Install or update with the official installer, which places the binary in
  `~/.local/bin` (already on Superkeet's search path):

  ```bash
  /bin/bash -c "$(curl -fsSL https://cua.ai/driver/install.sh)"
  cua-driver update --apply   # later upgrades
  ```

- Version 0.28.2 (September 2026) exposes 56 tools, every one annotated with
  `readOnlyHint` / `destructiveHint`, so Superkeet's approval classification
  uses the server's own hints rather than the name fallback. Observation tools
  such as `list_apps`, `list_windows`, `get_window_state`, and `verify_state`
  run automatically under the default policy; `click`, `type_text`,
  `press_key`, `kill_app`, and the browser tools ask first.
- macOS attributes its permission prompts to the **CuaDriver** app rather than
  to Superkeet. Grant Accessibility and Screen Recording with
  `cua-driver permissions grant` once, or approve the prompts on first use.
- Tool definitions are large (about 96,000 characters in total), so only the
  task-relevant subset fits the 4,096-token planning context. Superkeet's
  relevance ranking handles this.
- `get_window_state` returns a screenshot alongside the element tree by default.
  The on-device planner is text-only, so ask for the tree only when you can
  (`include_screenshot: false`), or prefer `list_windows` and `verify_state`.
- **Superkeet fills in the handles.** The 3B on-device model invented every
  `session`, `element_token`, `snapshot_id`, `pid` and `window_id` it was asked
  for. Session labels, tokens, and snapshot ids are removed from the tool schemas
  the model sees (`ObservationHandles.hidden`), and `ObservationBinding` remembers handles from the
  latest `get_window_state`, `list_windows` and `list_apps` results: the model
  names a control by `element_index` and Superkeet adds the matching token,
  snapshot id, pid and window id before the call leaves the app. A pid the model
  omits comes from the app the step is acting in, then from the latest
  observation, then from the frontmost window; an element always keeps the pid
  of the window it was observed in. Invented tokens, snapshot ids and session
  labels are dropped, so the server fails closed instead of acting on a guess.
  `get_window_state` requires a `window_id`; when a call needs one Superkeet has
  not seen for that app, or the model supplies an id absent from the app's
  `list_windows` / `get_window_state` observations, Superkeet runs `list_windows` for the pid itself
  (outside the step budget) and completes the call, instead of letting the
  model's first observation fail and cost a planning round trip. Every tool that
  accepts `session`, including the automatic window lookup, receives the same
  per-command label such as `sk-1a2b3c4d`. If a call reports that its session has
  ended, Superkeet calls `start_session` with that id once and retries the call
  within its existing timeout. Failed
  structured tools now keep their error text in the action log.
- Housekeeping tools (`check_permissions`, `check_for_update`,
  `get_cursor_position`, recording, session, cursor-theme, config and
  `kill_app`) are withheld from every plan (`ActionToolFilter.housekeepingNames`);
  offering them only invited the model to call them mid-command.
- Cua Driver annotates `click`, `type_text`, `press_key` and similar
  interactions as destructive. Superkeet classifies them as **changes state**
  (`MCPToolRiskClassifier.interactionNames`): the default policy still asks, but
  Just Do It runs them without a card. `kill_app` and real deletions stay
  destructive.

Notes:

- Servers are **user-installed**. Superkeet launches the command you provide as
  a local child process and talks to it over standard input/output.
- Superkeet resolves the login shell `PATH` (so `npx`/`uvx` installed via
  Homebrew work from the GUI app). You can always use an absolute command path.
- Environment variables can be set per server in the edit sheet, one `KEY=VALUE`
  per line.

## Permissions

- Superkeet already needs **Microphone** and **Accessibility**.
- macOS ties the Accessibility grant to the app's code signature. `install.sh`
  therefore signs local installs with the first “Apple Development” or
  “Developer ID Application” identity in the keychain, so the grant survives
  reinstalls; an ad-hoc signature (`CODESIGN_IDENTITY=-`) changes with every
  build and makes macOS ask again each time.
- Some MCP servers request their own macOS permissions on first use, such as
  **Screen Recording** (screenshot/automation servers) or **Accessibility**
  (computer-use servers). macOS attributes these to the server process, so you
  may see a separate prompt.

## Safety model

| Control | Default |
|---|---|
| Approval | **Only Ask Before Changes** — read-only tools, built-in `open_app` / `open_url` calls, and ⌘N / ⌘T shortcuts run automatically; other state-changing tools ask. Settings also offers **Ask Before Every Tool** and **Just Do It (YOLO)** |
| Ask Before Every Tool | Optional; confirms every tool call, including read-only tools and built-in app/URL opens |
| Just Do It (YOLO) | Optional; read-only and mutating tools run automatically, but destructive tools still require approval. The menu-bar **Auto-Approve Actions** toggle selects this policy; turning it off restores the asking policy that was active before |
| Plan card | Shown only when a predictable native step requires approval; **Approve All** pre-approves the exact native steps shown, **Step by Step** applies the selected policy per call, **Deny** stops that command |
| Approve similar | Per-command grant for the same “changes state” tool on the same app or process; never offered for destructive tools; cleared when the command ends |
| Instant app launch | On. Opening or activating an installed app named while speaking runs without approval; the later `open_app` call reuses it. Turn off under Settings ▸ Actions ▸ Instant App Launch |
| Keyboard shortcuts | `press_shortcut` is “changes state”; ⌘N / ⌘T run without asking by default, every other chord asks (`Press ⌘S in Notes`). Only a fixed key table is allowed; nothing is sent unless the target app is frontmost |
| Typing | `type_text` is “changes state” and exempt like `open_app`: the user dictated the words and named the app. Up to 4,000 characters; nothing is typed unless the target app is frontmost |
| Native clauses while speaking | Opens, URLs and searches run early under Instant App Launch; shortcuts and typing run early only when the policy would not ask about them. The command recognises them as done rather than repeating them |
| Listening session | Only while the pill is up. One press opens it, the shortcut or Escape closes it, two failed takes or a stopped engine close it, and the microphone is never open outside it |
| Interaction tools | `click`, `type_text`, `press_key`, `hotkey`, `scroll`, `drag`, `set_value` and similar are “changes state” even when a server annotates them destructive |
| Latency | Every action-log entry carries `sinceCommandMs` (from the recording start when live text was flowing, else the run start) and `durationMs` for the call itself |
| Concurrent approvals | FIFO queue; each request receives its own approve/deny decision |
| Command queue | Up to three waiting commands, run in arrival order as the active command finishes; **Escape** stops the run and clears the queue |
| Risk source | MCP tool annotations (`readOnlyHint`, `destructiveHint`), with a conservative name fallback for observation tools (`list_apps`, `get_app_state`, `list_pages`, `take_snapshot`, …) |
| Step budget | 12 tool calls per command |
| Per-tool timeout | 120 seconds |
| Command deadline | 180 seconds from the start of each command, excluding time in the queue and independent of the per-tool timeout; a stalled run is stopped and its pending approvals denied |
| Tool result size | 500-character redacted audit details, 800 characters fed back to the planner; projected observations read complete structured results up to 1 MB |
| Tool count | Up to 40 tools per plan, further limited to what fits the model context |
| Argument size | Up to 64 KB per call |
| URL arguments | Bare domains (for example `youtube.com`) are upgraded to `https://` before a tool runs |
| Browser choice | Naming a browser other than Chrome withholds the Chrome DevTools tools so the named browser is used |
| Audit log | On (`action-audit.log`), arguments and details redacted |

A tool with `readOnlyHint: true` is treated as read-only, as is an observation-style
tool that declares no behavior hints (for example `list_apps` or `get_app_state`).
A `destructiveHint: true` marks a tool destructive; anything that actually changes
state is mutating. An explicit `readOnlyHint: false` always wins over the name
fallback. Approvals show a concise intent (for example, `Run: open -a Helium`) with
full arguments behind **Details**.

Concurrent tool calls wait in the approval queue instead of being automatically
denied. Cancelling a waiting call removes just that request; cancelling the
action session dismisses and denies all outstanding approvals (including an
open plan card) and forgets the command's grants. HUD responses are bound to
the displayed request so a stale click cannot approve the next one.

### Cancellation and session ownership

Each action run owns its step budget, result cache, and in-flight preparation/tool
tasks. Ending the run invalidates its callbacks and cancels its outstanding
approval/tool work. A cancelled or completed planner cannot overwrite a
replacement run's HUD, progress, result, runtime issue, or task handle, and its
late tool callbacks are rejected before dispatch. A queued command starts only
after that cleanup, with fresh per-command state. Automatic handoff preserves
the previous runtime error; dismissing the outcome or manually starting a new
command while idle clears that run's own error while preserving unrelated
speech-engine errors.

Cancellation is recognized through nested Foundation Models `ToolCallError` and
`NSError` underlying-error wrappers. It is reported as a cancelled action rather
than a runtime failure; cancelled tool calls are recorded with a `cancelled`
audit outcome. Explicit approval denial remains a separate `denied` outcome.
Already-dispatched effects are not rolled back or automatically retried.

Cancelling a recording no longer restarts the speech engine. The engine's
`cancel` reply always reports `transcribing` because it flips the session phase
before its worker drains the audio, so Superkeet now probes `status` for up to
1.5 s (`EngineCancelPolicy`) and restarts only if the engine never returns to
idle.

MCP connection attempts have their own ownership tokens. Reconnect, cancellation,
and disconnection invalidate older attempts; late inventories and process-exit
callbacks can only affect the connection that produced them.

## Privacy

- Planning runs **entirely on-device** through Apple Intelligence. Prompts and
  tool results are not sent to a cloud model.
- The audit log lives at
  `~/Library/Application Support/Superkeet/action-audit.log` and redacts
   sensitive-looking argument keys (tokens, passwords, secrets, authorization,
   cookies, and similar), UI text/value/label fields, plus bearer/key-value
   secrets inside retained strings and tool output. Redaction precedes audit
   detail truncation.
- Ordinary `title` and `query` arguments remain readable for troubleshooting,
  including nested values. Secret-bearing values are always masked, including
  quoted values.

## Known limitations

- **No vision.** The on-device model accepts text only, so it cannot consume
  screenshots. Computer-use servers work only through their accessibility/element
  tree tools, not pixel-based vision.
- **Context window.** The on-device model has a small context (4,096 tokens on
  macOS 26.0; 8,192 was measured on a later system). Superkeet measures the real
  cost of each tool definition and only keeps the task-relevant subset that
  fits, round-robining across enabled servers so each one is represented. Tool
  results are trimmed to 800 characters for the model (observations are
  projected rather than cut, see above), multi-step commands run one fresh
  session per step, and an overflow after tools have run continues once from a
  condensed record. An overflow before any tool ran retries with a smaller tool
  set. If it still cannot fit, it explains the overflow and suggests a narrower
  request or fewer enabled servers.
- **macOS 26 only.** Actions Mode is unavailable on earlier macOS versions.
- **User-installed tooling.** Superkeet does not bundle Node, Python, or MCP
  servers.
- **Not sandboxed.** The app spawns local processes, so Actions Mode is not
  compatible with a Mac App Store sandbox.

## Troubleshooting

| Symptom | Check |
|---|---|
| “Could not find 'npx'” | Install Node (or use an absolute command path) |
| Chrome connection cannot attach | Start Chrome 144+, enable `chrome://inspect/#remote-debugging`, and allow the incoming connection |
| Active-tab request needs Chrome DevTools | Enable one Chrome DevTools server connected to the intended Chrome profile |
| The planner cannot identify the active tab | Focus the tab's page content; check that it belongs to the connected Chrome profile |
| Server stays “Not connected” | Run **Test** in Settings ▸ Actions and read the error excerpt |
| “Could not find 'cua-driver'” | Run the Cua Driver installer above, or set the command to `~/.local/bin/cua-driver` |
| Action says it needs macOS 26 | Update macOS and enable Apple Intelligence |
| “No MCP tools are available” | Add and enable a server, then **Reconnect All** |
| Tool call is denied | Approve the HUD, or change the approval policy |
