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
events remain immediate. This covers all splits and sidebar modes; it adds one
low-frequency monitor per pane, independent of the selected sidebar monitor.

## Regression coverage

- `SessionAttentionStateTests`: pure transition, de-duplication, time,
  acknowledgement, transfer, close, and stale-event cases.
- `SessionAttentionTrackerTests`: subscriptions, source replacement, teardown
  callbacks, pane-specific viewing, and deadline visibility checks.
- `SessionAttentionMetadataPollingTests` and
  `SessionAttentionMetadataSnapshotTests`: opt-in background scheduling,
  atomic provider changes, duplicate/expired progress, stopped sources.
- `SessionAttentionDockRendererTests`: numeric boundaries, scaling, original
  content-view ownership, icon changes, accessibility, and offscreen pixels.

Run the hosted suite with `macos/build.nu --action test`. For targeted runs,
pass `--only-testing GhosttyTests/<suite-name>` using the names above.
Runtime Dock behavior still needs testing in a GUI login session: change the
custom icon while a count is visible; clear it; quit and relaunch; confirm the
system/plugin icon returns without a stale count. The tests deliberately do
not write to the real Dock or change macOS security/developer settings.

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
