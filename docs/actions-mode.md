# Actions Mode

Actions Mode turns a spoken command into tool actions instead of text. You speak
a task, Superkeet opens apps/URLs natively or plans broader tasks with an
on-device model and local MCP tools, asking for your approval before changes.

Actions Mode is **off by default** and completely separate from dictation. A
normal recording still goes straight to the clipboard.

## Requirements

| Requirement | Why |
|---|---|
| macOS 26 | Provides the on-device Foundation Models framework |
| Apple Intelligence enabled | Supplies the on-device language model that plans tool calls |
| MCP servers for additional capabilities | Provide tools beyond the built-in app/URL opening tools |

If Apple Intelligence is unavailable, the Actions settings tab and onboarding
step explain the issue and the rest of the app continues to work normally.

## How it works

```text
Command Mode hotkey (default ⌥⇧Space)
    └── Speech → Parakeet (local, unchanged)
            └── AgentSessionController
                    ├── NativeActionExecutor → simple app/URL opens via NSWorkspace
                    ├── MCPClientManager   → local MCP server processes (stdio)
                    ├── On-device model    → plans tool calls
                    ├── ActionApprovalController → approve / deny each call
                    └── ActionAuditStore   → local, redacted log
```

1. Press the **Command Mode** shortcut and speak a task (for example, “open the
   pricing page and summarize it”).
2. Superkeet transcribes locally and applies your phrase replacements. Simple
   app/URL commands run directly; broader requests use the on-device planner.
3. Each tool call is classified as read-only, mutating, or destructive and, by
   default, shown in a floating HUD for approval. A multi-step command is shown
   once as a **plan card** instead (see “Approving a whole plan” below). While
   the action runs the HUD shows a checklist of steps and tool calls, and it
   shows the result when the action finishes.
4. Approved calls run through the native executor or MCP server. Planned tool
   results are truncated and fed back to the model until the task is done.
5. Press plain **Escape** once to stop an action. During Actions Mode, the event
   also reaches the focused app, so its normal Escape behavior still applies.
   Modifier combinations and autorepeat do not cancel a later action. Escape
   remains a consumed shortcut when only a speech recording is active.

### Built-in app and URL opening

These literal commands use native macOS APIs without a shell server, MCP
connection, planner call, or grounder decision:

- `open discord`
- `open Helium browser`
- `open Helium and go to youtube.com`
- `go to youtube.com in Helium`
- `open youtube.com` (uses the default browser)

Superkeet resolves registered bundle identifiers for known names/aliases, then
matches installed app names case-insensitively in `/Applications`,
`~/Applications`, and `/System/Applications` (including Utilities). Trailing
“app”/“browser” and punctuation are ignored for app-name matching; aliases such
as “Chrome” resolve to Google Chrome.

The built-in `open_app {name}` and `open_url {url, browser?}` tools use the same
approval HUD, timeout, step budget, and audit log as MCP calls. Compound requests
such as `open Helium and search for cats` go to the planner with these compact
tools available first. Only a missing-app resolution error permits the simple
path to fall through to planning. Denial, cancellation, timeout, and launch
failure stop the command rather than retrying an open operation.

`open_app` waits up to four seconds for the app to finish launching and show an
ordinary window, then reports `Opened Notes (pid 1234, com.apple.Notes). Its
window is on screen.` (or `No window has appeared yet.`). The pid and bundle
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
option/control). Approval shows `Press ⌘N in Notes`.

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

## Multi-step commands

`CommandDecomposer` splits a command at `and`, `and then`, `then`, commas,
semicolons and newlines — outside quotes, so `type "milk, eggs, and bread" into
Body` stays one step — and classifies each part on its own. Active-tab requests
are never split. A single-step command behaves exactly as before.

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

Three approval dialogs for one sentence is a poor fit for a voice command. So
before a multi-step command runs anything, Superkeet simulates it — the same
routing that will execute it, with opens assumed to succeed so later steps know
which app they act in — and shows one **plan card**:

```text
Approve this plan?          “open the notes app and create a new note”
  1. Already open: Notes (opened while you were speaking)
  2. Press ⌘N in Notes                                   Changes state
                              [Deny]      [Step by Step]  [Approve All]
```

- **Approve All** (Return) grants exactly the shown native steps — tool plus
  arguments — for this command. Anything different that comes up later still
  asks. Steps marked *Planned* use the on-device model; its tool calls were not
  shown, so they ask individually as usual.
- **Step by Step** runs the plan with a question for every tool call.
- **Deny** (Escape) stops before anything runs: “The plan was not approved, so
  no further steps ran.” An app that opened while you were speaking stays open.

The card only appears when at least one shown step would otherwise ask on its
own under the current approval policy; a plan made only of model-driven steps
runs straight away, since the card could not pre-approve anything. Single-step
commands never show it. Plan decisions are written to the action log as
`plan approved`, `plan step by step`, or `plan denied` with the step summaries.

### Approve similar

A tool-call approval offers **Approve Similar** (⇧Return) when the call is
“changes state” (never destructive) and names an app or process — `app`,
`browser`, `pid`, `bundle_id`, or a browser page id. It approves the call and
lets the same tool run again for the same target during this command without
asking, so a model that clicks three controls in Notes asks once. Grants are
forgotten when the command ends. Calls that ran under a grant are logged as
`succeeded (pre-approved)`.

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
screenshot, since it cannot see images. The native grounder keeps receiving the
complete observation.

Command Mode uses **phrase replacements only**, so a rule such as
`categolabs → catacolabs` can correct a spoken domain. Its app-scoped rules use the
app active when recording started. Filler removal and dictation's spoken-editing
commands do not alter command arguments. An incomplete/partial command shows a
retry error and never enters the clipboard/paste path.

### Live command recognition

Historically Parakeet returned text only after a recording stopped, so nothing
could react while you were still speaking. Instant app launch needs interim
text, which Superkeet takes from one of two recognisers behind the
`PartialTranscriptSource` seam, chosen per recording by `PreferredPartialSource`:

1. **The Parakeet engine itself** (`DaemonPartialSource`), when the running
   daemon speaks protocol 2 (parakeet-cli 0.1.7+). A Command Mode recording
   sends `{"command":"start", …, "partials":true}` and the daemon streams
   `{"type":"partial","text":…,"sequence":n,"truncated":…}` events roughly
   every 0.75 s of captured audio. One model produces both the interim and the
   final text, so the app name that triggers an early launch is exactly the one
   the command will see; there is no second microphone consumer, no second
   speech model, and it works on every macOS version Superkeet supports. The
   `partials` flag is only sent when Instant App Launch could act on it, so an
   ordinary dictation or a disabled feature costs the engine nothing.
2. **Apple's on-device `SpeechAnalyzer`** (`SpeechAnalyzerPartialSource`, macOS
   26) as the fallback while the daemon is not running yet or is a protocol-1
   engine. `MicrophoneTapHub` owns one `AVAudioEngine` input tap that the
   overlay meter and this recogniser share. Volatile results with the fast
   preset recognise an app name about one second into the sentence; installed
   app names are supplied as contextual strings; speech assets are reserved per
   app and a download is only offered, never started automatically.

Both deliver `PartialTranscript` values (running text, a final flag, a sequence
number) to the same detector. The final transcript always comes from Parakeet's
`complete` event. Settings ▸ Actions ▸ Instant App Launch shows which recogniser
the next recording would use.

Interim text from the engine is advisory: it is decoded from audio no committed
segment owns yet, with 0.3 s of silence appended so the decoder finishes the
last word instead of inventing a tail. A partial's final word may change in the
next one; the detector's stability rule (two consecutive partials naming the
same installed app) exists for exactly this. Superkeet accepts daemon protocols
1 and 2 and ignores event types it does not know, so engine and app releases
need not be lock-stepped.

#### Deciding what may run early

`SpeculativeIntentDetector` reads the running text and decides, at most once per
recording, that an app should open or come forward before the sentence ends.
It is plain string handling over the installed-app inventory, so every rule
below is covered by scripted tests, including the recogniser's recorded output
for “open the notes app and create a new note”.

- Leading filler (“hey”, “please”, “um”, “can you”, “superkeet”, …) is skipped.
  The clause must then start with `open`/`open up`/`launch` (a launch) or
  `switch to`/`switch over to`/`activate`/`bring up`/`go to` (an activation).
- The app reference runs from the verb to the first clause boundary (`and`,
  `and then`, `then`, `to`, `so`, a comma/semicolon/colon, or a sentence-ending
  period) and resolves through the same `AppResolver` as `open_app`, so “the
  Notes app” and aliases such as “Chrome” work. Conjunctions inside names
  (“Android Studio”) are not boundaries.
- A launch commits when any of these holds: a boundary followed the name; the
  same app was named by two consecutive partials **and** no other installed
  name extends the spoken one (“Safari” waits while “Safari Technology Preview”
  is installed); or the recogniser finalized the text.
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
on) turns the detector's decision into an action. `SpeculativeLaunchCoordinator`
listens from the moment a Command Mode recording starts:

1. `ParakeetService.startRecording` calls `begin(sessionID:)` when Command Mode
   is armed. The coordinator starts the interim-text source and creates a
   detector for that session.
2. When the detector commits, the app opens through `NativeActionExecutor`
   directly — **without the approval HUD**. This bypass is limited to opening or
   activating an installed app that the user just named; the regular `open_app`
   tool keeps its “changes state” risk and approval. The HUD shows “Opening
   Notes…”, then “Opened Notes”, while the recording overlay stays up.
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
a new note” (2.23 s of speech), Notes launches about 2.07 s in with the default
stability threshold of two consecutive partials, or about 1.14 s in when a
single partial is trusted (`SpeculativeLaunchCoordinator(stabilityThreshold:)`).

If the final transcript names a different app than the one launched, the
launched app stays open, the command opens the app it actually asked for, and
the activity log notes the disagreement.

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

Only **enabled** servers contribute tools to a plan. **Test** and **Reconnect**
can establish diagnostic connections, but a connected server with its toggle off
is excluded. If a request needs planning and no MCP servers are enabled, the HUD
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
   relevance ranking handles this today. The optional native grounder below
   exposes compact single-step click and text-entry tools to the planner.
- `get_window_state` returns a screenshot alongside the element tree by default.
  The on-device planner is text-only, so ask for the tree only when you can
  (`include_screenshot: false`), or prefer `list_windows` and `verify_state`.

Notes:

- Servers are **user-installed**. Superkeet launches the command you provide as
  a local child process and talks to it over standard input/output.
- Superkeet resolves the login shell `PATH` (so `npx`/`uvx` installed via
  Homebrew work from the GUI app). You can always use an absolute command path.
- Environment variables can be set per server in the edit sheet, one `KEY=VALUE`
  per line.

## Native UI grounder (experimental)

Enable **Settings ▸ Actions ▸ Native UI grounder** to use
`lucataco/gliner2.5-cua-grounder-macos-v1` for native control selection. Apple
Intelligence continues to plan broader tasks. The fine-tune receives one supplied
step and a bounded menu of eligible actions; it returns only a candidate ID and
scores. Tool arguments and accessibility capabilities remain in Superkeet.

### Setup

1. Install Python 3.12 and Cua Driver 0.28.2 with Accessibility permission.
2. From this checkout, run:

   ```bash
   bash scripts/install_grounder.sh
   ```

   This creates `~/Library/Application Support/Superkeet/Grounder/venv`, installs
   the pinned Python dependencies, and downloads the pinned model revision.
   App inference uses the local cache in offline mode. Packaged apps include the
   two worker scripts; Python, PyTorch, and model weights remain user-installed.
3. Enable one MCP server named **cua-driver**, enable the native grounder, and
   click **Check and Warm Runtime**. The worker uses MPS on Apple Silicon,
   unloads after ten idle minutes, and stops at app shutdown. Startup has a
   60-second deadline; warm decisions have a two-second deadline. Failed or
   cancelled transports are discarded, with a five-second restart backoff.

Literal single-step templates run directly:

- `Click Save in Notes`
- `Type "Meeting notes" into Title in Notes`

For broader wording or multi-step tasks, Apple Intelligence supplies `app`,
`target`, and exact replacement `text` through `superkeet_native_click` or
`superkeet_native_set_text`. Text entry replaces the field's entire value.
Each step requires one exact named app with one visible window. Candidate
eligibility requires target words in the control's label/section, an appropriate
native role/action, and a current `element_token`. Disabled, unlabeled, secure,
web-content, and ambiguous controls are excluded or rejected. Use the visible
label and section to narrow a target; browser DOM grounding is not implemented.

Grounding helpers are offered for click, text-entry, and unclassified intents.
Recognized app-opening, URL-opening, search, active-tab navigation/find, switching, reading, key, and scroll
intents go directly to the planner with their original tool inventory, so native
grounding does not consume their tool budget or intercept those calls.

### Execution and verification

- Native observations use MCP `structuredContent`, bypass the result cache, and
  remain complete up to a 1 MB limit. Screenshots are disabled.
- Each choice uses a new accessibility snapshot. `reobserve` permits at most one
  additional selection round; `abstain` and exhausted rounds stop without a
  mutation or automatic planner fallback.
- The normal approval HUD shows the selected control, operation, app, and value.
  After approval, another audited snapshot must identify the same unchanged
  control before its capability is renewed. A changed or stale target stops the
  step instead of selecting another control. This extra observation counts
  against the command's step budget.
- Exactly one mutation is dispatched. A fresh post-action observation verifies
  text replacement by matching control identity and reading its actual value.
  Generic clicks have no independent success postcondition, so the result is
  reported as unverified and the task stops. Denial, cancellation, refusal,
  timeout, or failed verification never causes an automatic retry.
- Audit entries include the selected ID, confidence, and chooser latency.
  UI text/values and element tokens are redacted, and raw native observations
  and action output are omitted from audit details. Tool delivery success is
  separate from the independently verified result shown to the user.

The model's softmax scores are not calibrated safety probabilities. See the
[grounding evaluation](custom-grounder-evaluation.md) for the measured scope.

## Permissions

- Superkeet already needs **Microphone** and **Accessibility**.
- Some MCP servers request their own macOS permissions on first use, such as
  **Screen Recording** (screenshot/automation servers) or **Accessibility**
  (computer-use servers). macOS attributes these to the server process, so you
  may see a separate prompt.

## Safety model

| Control | Default |
|---|---|
| Approval | **Only Ask Before Changes** — read-only tools run automatically; anything that changes state is confirmed |
| Optional | **Ask Before Every Tool** confirms even read-only tools |
| Plan card | A multi-step command asks once up front; **Approve All** pre-approves only the exact native steps shown, **Step by Step** asks per call, **Deny** runs nothing |
| Approve similar | Per-command grant for the same “changes state” tool on the same app or process; never offered for destructive tools; cleared when the command ends |
| Instant app launch | On. Opening or activating an installed app named while speaking runs without approval; the later `open_app` call reuses it. Turn off under Settings ▸ Actions ▸ Instant App Launch |
| Keyboard shortcuts | `press_shortcut` is “changes state” and asks for approval by default (`Press ⌘N in Notes`). Only a fixed key table is allowed; nothing is sent unless the target app is frontmost |
| Concurrent approvals | FIFO queue; each request receives its own approve/deny decision |
| Risk source | MCP tool annotations (`readOnlyHint`, `destructiveHint`), with a conservative name fallback for observation tools (`list_apps`, `get_app_state`, `list_pages`, `take_snapshot`, …) |
| Step budget | 12 tool calls per command |
| Per-tool timeout | 120 seconds |
| Command deadline | 180 seconds for the whole command, independent of the per-tool timeout; a stalled run is stopped and its pending approvals denied |
| Tool result size | 500-character redacted audit details, 800 characters fed back to the planner; bounded native observations use complete structured results up to 1 MB |
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

### Phase 4: cancellation and session ownership

Each action run owns its step budget, result cache, and in-flight preparation/tool
tasks. Ending the run invalidates its callbacks and cancels its outstanding
approval/preflight work. A cancelled or completed planner cannot overwrite a
replacement run's HUD, progress, result, runtime issue, or task handle, and its
late tool callbacks are rejected before dispatch. Retrying clears the previous
run's own runtime error while preserving unrelated speech-engine errors.

Cancellation is recognized through nested Foundation Models `ToolCallError` and
`NSError` underlying-error wrappers. It is reported as a cancelled action rather
than a runtime failure; cancelled tool calls are recorded with a `cancelled`
audit outcome. Explicit approval denial remains a separate `denied` outcome.
Already-dispatched effects are not rolled back or automatically retried.

MCP connection attempts have their own ownership tokens. Reconnect, cancellation,
and disconnection invalidate older attempts; late inventories and process-exit
callbacks can only affect the connection that produced them.

## Privacy

- Planning runs **entirely on-device** through Apple Intelligence, and optional
  native grounding runs locally through GLiNER. Prompts and tool results are not
  sent to a cloud model.
- The audit log lives at
  `~/Library/Application Support/Superkeet/action-audit.log` and redacts
   sensitive-looking argument keys (tokens, passwords, secrets, authorization,
   cookies, and similar), UI text/value/label fields, plus bearer/key-value
   secrets inside retained strings and tool output. Redaction precedes audit
   detail truncation.
- Ordinary `title` and `query` arguments remain readable for troubleshooting,
  including nested values. Grounding/AX observations use a stricter context that
  masks their titles and queries as UI content and omits raw output details.
  Secret-bearing values are masked in either context, including quoted values.

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
