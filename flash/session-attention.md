# Agent-session attention

## Incremental implementation

1. Keep attention policy in a pure value state machine, with an injected clock.
   Track panes independently and count their owning sessions once.
2. Publish coherent provider/status snapshots from the existing metadata
   monitor. Add an opt-in low-frequency consumer without changing sidebar
   polling defaults or provider classification rules.
3. Subscribe one attention monitor per live split, using the existing shared
   refresh scheduler. Reconcile ownership after split transfers; reject old
   callbacks after removal. Only the focused pane of the active key window is
   considered viewed.
4. Render a temporary upper-left Dock badge in the application process. Leave
   the native bell badge, Dock plug-in, on-disk icon, saved-state schema, user
   preferences, and notification authorization untouched.
5. Resolve changed foreground PIDs on title/progress events without waiting
   for the background tick. Retain a bounded, process-scoped reduction of the
   latest round while asynchronous provider discovery is pending.
6. Project the same unread/input state into per-session sidebar summaries.
   Fan out only changed values to each row; do not add a second detector,
   acknowledgement path, timer, or persisted preference.

## Policy

| Observation | Effect |
| --- | --- |
| Ordinary shell, initial Ready, or initial Complete | No reminder |
| Codex/Claude Active | Arm the round; clear its previous reminder |
| Codex/Claude Needs input | Immediate reminder, including while viewed |
| Armed round becomes Complete | Queue unread completion for one second |
| Active resumes during that second | Cancel transient completion |
| Focus completed pane in active key window | Clear only that pane's completion |
| Ready, Failed, other tool, or closed pane | Clear that pane's reminder |
| Move a live split between sessions | Preserve reminder; change owning count |
| Close/quit/relaunch | No persisted reminder |

The one-second delay smooths short completion transitions. It cannot turn the
existing heuristic provider into an authoritative agent-event API. No output
silence timer was added. Claude's last-screen prompt matching retains its known
false-positive/false-negative limitations.

Each attention monitor polls in the existing background mode (every third tick
of the single app-wide one-second scheduler). Title and structured progress
events check the foreground PID immediately. A changed PID triggers coalesced
off-main discovery; its events are not classified under the previous process's
cached provider. This covers all splits and sidebar modes; it adds one
low-frequency monitor per pane, independent of the selected sidebar monitor.

If discovery finishes after a short round, the monitor replays only the minimal
active/completed evidence, with its original observation time. The one-second
delay starts at completion, not at lookup delivery. Viewing the pane after that
completion acknowledges it even if provider discovery finishes after focus has
moved away. Superseded approval events are not replayed as transient reminders.
Progress display expiry is not completion; an explicit completion cannot be
undone by an unchanged spinner title. Unknown-PID events are not attributed to
the last known agent, and stale lookup results cannot cross a PID or binding
change. Bootstrap progress is accepted only for its recorded process.

Remaining detection limits: an agent launched via same-PID `exec` is still
discovered by periodic revalidation, so a full first round before that discovery
can be missed. A process that exits before its identity can be resolved can also
lose its pending evidence. Events with no readable foreground PID are ignored
rather than guessed. These are best-effort observational reminders, not a
guarantee that every agent completion or approval will be detected.

## Sidebar cues

- Unread completed results use a green `Unread` text/icon pill, a semibold
  session title, and a subtle green row background.
- Pending approval/input uses an orange `Needs input` text/icon pill and
  orange row background. Viewing the session alone does not dismiss it.
- If different panes in one session need attention for both reasons, input
  takes visual priority. The Dock still counts the session only once.
- Viewing a completed pane clears its unread reason. Another unread or
  input-waiting pane can keep the session highlighted. Once no pane needs
  attention, the row returns to its ordinary appearance.

The selected-row outline and leading stripe remain visible. Rows never flash
or reorder because of attention. Text, symbols, tooltips, and accessibility
descriptions supplement color. The compact labels use English, matching the
existing sidebar controls.

The metadata icon's `Complete` activity status is not an unread flag: it can
remain after acknowledgement. Prominent cues instead use the same mature
unread/input state that contributes to the Dock count. Reason changes and
ownership moves update the affected rows even when the total count is unchanged.

## Regression coverage

- `SessionAttentionStateTests`: pure transition, de-duplication, time,
  acknowledgement, transfer, close, and stale-event cases.
- `SessionAttentionTrackerTests`: subscriptions, source replacement, teardown
  callbacks, pane-specific viewing, deadline visibility checks, and delayed
  completion acknowledgement across focus changes; summary updates at a stable
  count, mixed split reasons, and stopping during synchronous summary delivery.
- `SessionAttentionStoreTests`: immediate per-session state, deduplication,
  ownership changes, clearing, and subscription cancellation.
- `SessionAttentionSidebarTests`: no cue for acknowledged state, explicit text
  and symbol mapping, and input priority over unread completion.
- `SessionAttentionMetadataPollingTests` and
  `SessionAttentionMetadataSnapshotTests`: opt-in background scheduling,
  atomic provider changes, duplicate/expired progress, stopped sources.
- `SessionAttentionDockRendererTests`: numeric boundaries, scaling, original
  content-view ownership, icon changes, accessibility, and offscreen pixels.
- `SessionPendingProcessActivityTests`: constant-space evidence reduction,
  provider-specific classification, disarming transitions, and final-state
  replay without historical approval flashes.
- `TerminalSessionProcessAttributionTests`: real monitor/tracker integration
  with deterministic process lookup and clocks; fast first rounds, stale
  spinners, bootstrap provenance, ordinary-process rejection, PID changes,
  unavailable PID recovery, failed lookups, rebinding, and teardown.

Run the hosted suite with `macos/build.nu --action test`. For targeted runs,
pass `--only-testing GhosttyTests/<suite-name>` using the names above.
Runtime Dock behavior still needs testing in a GUI login session: change the
custom icon while a count is visible; clear it; quit and relaunch; confirm the
system/plugin icon returns without a stale count. The tests deliberately do
not write to the real Dock or change macOS security/developer settings.

For validation alongside a running development build, pass `--build-dir` with
a fresh directory as well as an xcconfig containing a unique app bundle ID.
Changing only `CONFIGURATION_BUILD_DIR` is **not** sufficient isolation: Xcode
can remove previous app products as stale output when DerivedData is shared.
Do not reuse another running build's DerivedData or its build database.

## Validation on 2026-09-04

- Universal ReleaseLocal app build: passed (`arm64` and `x86_64`), including
  strict code-signature verification and CLI startup.
- Debug app and complete test targets: `build-for-testing` passed under a
  separate validation bundle identity.
- Metadata tests: 55 passed against the real Debug app dylib (6 new and 49
  existing regressions), using a standalone Swift Testing runner. Two existing
  tests requiring complete app/view initialization were excluded explicitly.
- State/tracker: 27 tests passed, including real automatic timer expiration
  and cancellation. Renderer: 9 tests passed, including actual offscreen
  pixels and a reviewed `1` / `12` / `99+` preview. Together with the metadata
  regressions, 91 tests passed (parameterized cases add further coverage).
- Strict SwiftLint: zero violations across 265 source/test files.
- An isolated Debug app with synthetic terminal signals launched and exited
  successfully. The computer-use tool timed out while inspecting the Dock, so
  live badge display/clear, custom-icon switching, and quit/relaunch behavior
  are **not claimed as end-to-end verified**.

Developer Mode remained disabled. No security settings were changed, no agent
credentials were used, and the installed `/Applications/FLASH-Ghostty.app` and
its running sessions were left untouched. The full GUI-hosted test suite was
not run as part of this validation.

### Review follow-up: delayed process attribution

- Final Debug app and test targets: `build-for-testing` passed; deep strict
  signature verification and CLI startup passed.
- Universal ReleaseLocal app: `arm64` and `x86_64` build, deep strict signature
  verification, and CLI startup passed. This is a local candidate build, not a
  notarized or published release.
- 128 tests in 23 suites passed against the final production Debug dylib,
  including both new pending-activity/process-attribution suites. The same two
  existing app/view-initialization tests were explicitly excluded. No
  production classes were replaced with stubs in this combined run.
- Strict SwiftLint: zero violations across 268 source/test files; the final
  unknown-PID guard and integration tests also passed scoped strict lint.
- No stable release was published. Live Dock/custom-icon GUI acceptance and
  the detection limits above remain outstanding.

During this follow-up, sharing DerivedData despite a separate products
directory caused Xcode to remove the previous manual-test app's `Contents`
under `macos/build/Debug`. The running process was not stopped. The installed
`/Applications/FLASH-Ghostty.app` remained present and passed strict signature
verification. The old Debug app was rebuilt from pre-fix commit `5a920f2bd`
with its original validation bundle ID and wholly separate source/build trees,
then its missing `Contents` was restored atomically. Its strict signature and
747 file hashes matched the verified recovery build, and the original process
remained running. This was a baseline reconstruction, not a byte-identical
backup of the deleted binary. The unused prior ReleaseLocal products were also
cleaned; the verified new candidate app was copied back to
`macos/build/ReleaseLocal`.
This is why isolated validation must use a fresh `--build-dir`, not just a
products-directory override.

### GUI acceptance follow-up on 2026-09-05

- A dedicated arm64 ReleaseLocal candidate at `8646f7305` was built with fresh
  DerivedData and a recognized `.debug.ui-tests.run-` bundle identity, keeping
  the app and Dock helper in the same isolated defaults domain.
- Real Codex 0.153.4 ran a harmless `sleep 4` instruction. Its background
  sidebar state changed from Active to Complete; subsequently opening the
  session confirmed the command result and `DOCK-COMPLETE` reply. This verifies
  the visible provider state, **not** the system Dock count or acknowledgement.
- A first harmless approval probe executed without an observable approval
  prompt. A new read-only test invocation with `approvals_reviewer="user"`
  produced a real, pending one-time `printf` approval. The sidebar showed
  Needs input while selected, after switching away, and after returning.
  The user confirmed an actual red Dock badge showing 1 at this pending
  approval checkpoint, after the session had been revisited. A one-time
  approval then produced the expected command output and `DOCK-APPROVED`;
  the selected session changed from Needs input to Active to Complete.
  The user confirmed that the badge disappeared after the approved command
  completed in the viewed pane. This visually verifies pending approval 1
  through one-time approval to viewed completion with no badge; the exact
  clearing point during the transient Active state was not observed.
  No persistent command-prefix approval or global approval configuration
  was changed.
- A later round in QA Approval changed from Active to Complete while that
  session was in the background. The user observed the actual red Dock badge
  showing 1, then confirmed that clicking the corresponding session cleared
  it. This passes user-assisted acceptance of single-session background
  completion display and acknowledgement. It does not retroactively verify
  the Dock state of the earlier `DOCK-COMPLETE` round.
- Two later background Codex rounds produced a user-observed Dock count of 2;
  both actual final replies were subsequently verified. The user's clearing
  report did not establish the intermediate count after visiting only one
  session, so that first report alone did not verify ordered clearing or
  establish a bug.
  A controlled recheck completed two new background rounds and opened only
  QA Codex. The user confirmed that Dock 1 remained for the other unread
  session, so cross-session clearing was not reproduced. The remaining
  QA Approval session was then opened and its actual final reply verified;
  the user confirmed that the last badge disappeared. Together these checks
  verify a count of two and independent per-session acknowledgement. They are
  not one continuously captured `2 -> 1 -> 0` trace: the recheck's initial
  count of 2 was not separately captured.
- Claude Code 2.1.59 reached its first-run login-method screen. No account
  login or paid-service selection was performed; real Claude completion and
  approval acceptance remains pending authentication.
- Added explicit accessibility getter assertions for the Dock view's initial
  role/label and count updates (including unclipped 100 and nonpositive counts).
  All 10 renderer tests passed against the previously verified production Debug
  dylib, without production stubs. Scoped strict SwiftLint passed with zero
  violations. Production code was unchanged; the combined 128-test suite was
  not rerun in this follow-up.
- Added a two-session Tracker regression: two unread completions count as 2;
  viewing one leaves 1 through repeated visibility refreshes and duplicate
  completion updates; viewing the other clears it. All 14 Tracker tests passed
  against the same real production Debug dylib. Scoped strict SwiftLint and
  `git diff --check` passed. No production implementation was changed.

Computer-use window inspection works but has intermittent long delays;
automated Dock inspection remains unavailable. User observation confirms the
single pending-approval badge and its absence after one-time approval and
viewed completion, as well as a later single-session background-completion
badge and its clearance after selecting that session. A two-session count of
2 was also observed; a controlled recheck confirmed one reminder remains after
viewing only one session, and disappears after viewing the remaining session.
Real Claude behavior, custom-icon switching, and quit/relaunch
scenarios remain unverified.
These observations do not qualify the candidate for a stable release.

### Sidebar prominence follow-up on 2026-09-05

- Added the sidebar cues described above using the Dock tracker's per-session
  unread/input summaries. Detection, completion delay, acknowledgement rules,
  session ordering, and saved preferences are unchanged.
- An isolated arm64 Debug app and all test targets passed `build-for-testing`
  with a fresh build directory and recognized `.debug.ui-tests.run-` identity.
  The initial sandboxed attempt failed in Xcode's icon asset compiler; the
  normal-permission retry succeeded without source or asset workarounds.
- 142 tests in 25 suites passed against this new production Debug module and
  dylib, including state, tracker, store, sidebar presentation, Dock renderer,
  and process-attribution regressions. Only the two existing full-app/view
  initialization tests, `metadataInvalidationDoesNotInvalidateTheTerminalController`
  and `glassAvailability`, were explicitly excluded. The GUI-hosted suite was
  not executed and production classes were not replaced with stubs.
- Scoped strict SwiftLint passed with zero violations across all 11 changed
  Swift source/test files. Independent code review found no blocking issue in
  this increment.
- Rendered the actual production `TerminalSessionAttentionBadge` offscreen in
  light and dark mode at 9, 9.75, and 12 pt row-name sizes. All 12 combinations
  fit the checked bounds; the longest pill was 88 x 17 pt (the badge font caps
  at 10 pt). Both preview sheets were visually inspected with no clipped text
  or symbols. This validates the badge component, not complete sidebar layout,
  inline renaming, or live end-to-end interaction.
- Deep strict app signature verification and command-line version startup
  passed. Critical file hashes of both previously running test apps remained
  unchanged. Neither app was restarted or overwritten; no new Codex/Claude
  prompts, account settings, or macOS security settings were used or changed.

The earlier human-assisted Dock acceptance applies to the pre-sidebar
candidate, not this new build. Complete sidebar GUI acceptance (including the
minimum width, inline renaming, and per-pane clearing) remains to be performed.
This increment is a local test candidate, not an installed or published release.
