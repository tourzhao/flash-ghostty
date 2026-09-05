# Agent-session Dock attention

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

## Regression coverage

- `SessionAttentionStateTests`: pure transition, de-duplication, time,
  acknowledgement, transfer, close, and stale-event cases.
- `SessionAttentionTrackerTests`: subscriptions, source replacement, teardown
  callbacks, pane-specific viewing, deadline visibility checks, and delayed
  completion acknowledgement across focus changes.
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
