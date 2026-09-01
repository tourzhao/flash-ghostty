<div align="center">
  <h1>⚡ FLASH-Ghostty</h1>
  <p><strong>A session-centered macOS terminal workspace for shell, Codex, and Claude Code.</strong></p>
  <p>
    Keep parallel coding sessions visible, work with project files beside the terminal,
    return to important output, and restore the shape of your workspace after a restart.
  </p>
  <p>
    <a href="#what-flash-ghostty-adds">Features</a>
    ·
    <a href="#typical-workflow">Workflow</a>
    ·
    <a href="#build-from-source">Build from source</a>
    ·
    <a href="#configuration">Configuration</a>
    ·
    <a href="#relationship-to-ghostty">Ghostty relationship</a>
    ·
    <a href="#contributing">Contributing</a>
  </p>
  <p>
    <a href="https://github.com/tourzhao/flash-ghostty/actions/workflows/flash-branch-validate.yml"><img alt="FLASH-Ghostty branch validation" src="https://github.com/tourzhao/flash-ghostty/actions/workflows/flash-branch-validate.yml/badge.svg"></a>
    <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  </p>
</div>

## About

FLASH-Ghostty is an independent, macOS-focused fork of
[Ghostty](https://github.com/ghostty-org/ghostty). It keeps Ghostty's fast Zig
terminal core and native SwiftUI/Metal application, then adds a workspace layer
for people who run several shells and coding agents at the same time.

The goal is not to hide the terminal behind an agent-specific client. Codex,
Claude Code, and ordinary shell programs still run as normal terminal
processes. FLASH-Ghostty organizes and observes those sessions, connects each
one to its working directory, and gives the user native tools for navigating
their files and output.

> [!IMPORTANT]
>
> This repository currently has no supported public installer or permanent
> binary download. You do not need a Developer ID certificate or App Store
> Connect credentials to clone, build, modify, or contribute to the source.
> Apple distribution credentials are only needed to run the optional
> signed-and-notarized release-candidate workflow or to distribute a notarized
> app. Automatic updates are disabled and no FLASH-Ghostty update feed is
> configured.

## Typical workflow

1. Open native tabs for a shell, Codex, or Claude Code. Each one appears as a
   named session in the left sidebar with its detected tool, activity, and
   latest detected instruction. The selected terminal's working directory is
   shown in the header above it.
2. Use the folder button in the working-directory header to show or hide the
   right file browser for the selected session.
3. Command-click a detected local path in terminal output to open it with a
   native app or reveal it in the session's file browser.
4. When output becomes long, scroll up and add numbered pins to the parts you
   need to revisit; use the bottom control to return to live output.
5. Quit normally and, at the next launch, choose whether to rebuild the saved
   window, tab, split, name, directory, sidebar, and filter layout.

## What FLASH-Ghostty adds

### A session workspace instead of a row of anonymous tabs

The session sidebar turns native terminal tabs into a searchable workspace.
Each row can show:

- the session name;
- whether the foreground tool is Codex, Claude Code, or a regular terminal;
- an observed activity state: Ready, Active, Needs input, Complete, or Failed;
- the most recent instruction that can be identified from visible terminal
  content; and
- familiar terminal signals such as a bell and tab color.

From the sidebar you can create, select, search by name, rename, and close
sessions, including closing the sessions to the right or every other session.
Session ordering and selection stay aligned with the underlying native tab
group. The sidebar width and session text size are adjustable. The selected
terminal's shell-reported working directory appears in a separate header above
the terminal.

Activity indicators are deliberately observational. FLASH-Ghostty uses local
process, title, progress, and terminal-content evidence; it does not require a
Codex or Claude account integration and does not claim to control the agent.

### A Finder-style file browser tied to each session

Open the file sidebar to browse the selected session's shell-reported working
directory without leaving the terminal. It follows that session as the working
directory changes. The selected file-type filters belong to the session and
are restored with it.

The browser includes:

- back, forward, working-directory root, and refresh controls;
- Name, Date Modified, and Kind columns, with sorting by name or modification
  date;
- filename search and exact file-type filters while keeping directories
  navigable;
- a hidden-file toggle and persistent per-session filter selection;
- new folder, rename, duplicate, copy, paste, and Move to Trash actions;
- multi-selection and standard macOS file-URL pasteboard interoperability with
  Finder;
- contextual Open, Show in Finder, and Copy Path actions, plus `⌘C`, `⌘V`, and
  `⌘Delete` while the file list has focus; and
- live directory refresh driven by FSEvents.

File mutations are rooted in the directory the browser originally opened and
revalidated before use. The implementation uses descriptor-anchored operations
and fails closed when a root or destination changes unexpectedly, reducing
symlink-swap and time-of-check/time-of-use risks during copy, paste, rename,
duplicate, and trash operations.

### Native actions for file paths printed in the terminal

When terminal output contains a detected local file path, FLASH-Ghostty resolves
it against the source session's working directory and presents native actions
instead of blindly launching it. Relative paths, home-relative paths, `file:`
URLs, and compiler-style `path:line:column` locations are recognized. The line
and column suffixes identify the file but are not currently passed to an editor
for cursor navigation.

Depending on the target and the available applications, the menu can offer:

- **Open in _Application_**;
- **Open With**;
- **Show in File Browser** when the file belongs to the session's browser root;
  or
- **Show in Finder** for targets outside that root.

Unsafe executable targets are reveal-only. Before an action is dispatched, the
source window, session, surface, working-directory relationship, and file
identity are checked again so a delayed menu action cannot silently act on a
different session or substituted file.

### Scrollback pins for long-running work

FLASH-Ghostty overlays lightweight navigation controls on each terminal
surface:

- once you have scrolled into history, pin the current viewport;
- keep up to five numbered positions per surface;
- click a pin to return to that exact part of terminal-owned history;
- right-click a pin to remove it; and
- use **Scroll to Bottom** to return to the newest output.

Pins carry the terminal history identity they were created against. If that
history is replaced or can no longer be verified, stale pins are removed rather
than jumping to unrelated output. Pins are intentionally ephemeral and are not
part of saved-session restoration.

For new sessions, FLASH-Ghostty sets
`CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1` by default so Claude Code output remains
in terminal-owned scrollback where pins can address it. This can be cleared in
the user configuration if alternate-screen behavior is preferred.

### Honest workspace restoration

On launch, FLASH-Ghostty can offer to restore the previous workspace or start
fresh. Restoration reconstructs the durable structure of the workspace:

- windows, native tab groups, session order, and selected session;
- custom session names and working directories;
- split trees and the focused split;
- session-sidebar and file-sidebar visibility; and
- the selected file-type filters for each session.

It does **not** pretend that a terminal process survived. Running commands,
terminal output, Codex processes, and Claude Code processes cannot be resumed by
this feature. Instead, restored terminals start new processes in their recorded
working directories. The launch prompt states that limitation before the user
chooses to restore.

## What remains Ghostty

FLASH-Ghostty continues to use Ghostty's shared terminal engine and native macOS
application foundation. That includes standards-oriented terminal emulation,
GPU-accelerated Metal rendering, shell integration, windows, tabs, splits,
themes, key bindings, and the broader Ghostty configuration model.

The FLASH workspace features described above are currently macOS-specific. The
repository still contains Ghostty's shared Zig core and other platform code,
but this fork's product work and validation are centered on the macOS app.

## Build from source

FLASH-Ghostty currently targets macOS 13 or later. Building the macOS app from
the current `main` branch requires:

- Zig 0.16.0;
- Xcode 26 with the macOS 26 SDK and Metal Toolchain; and
- [Nushell](https://www.nushell.sh/) for the macOS build driver.

Clone the fork:

```shell
git clone https://github.com/tourzhao/flash-ghostty.git
cd flash-ghostty
```

Build the shared core, then the debug macOS app with the FLASH product overlay:

```shell
zig build -Demit-macos-app=false

macos/build.nu \
  --configuration Debug \
  --xcconfig "$PWD/macos/Configurations/FlashGhostty.Debug.xcconfig" \
  --locked-packages \
  --action build
```

The app bundle is written to
`macos/build/Debug/FLASH-Ghostty.app`. This local development build does not
require release-signing or notarization credentials.

Useful development checks include:

```shell
# Shared Zig tests
zig build test

# A targeted Zig test
zig build test -Dtest-filter="test name"

# macOS unit tests
macos/build.nu --configuration Debug --locked-packages --action test

# Swift lint and formatting
swiftlint lint --strict --fix
```

See [HACKING.md](HACKING.md) for the inherited Ghostty development notes and
[flash/README.md](flash/README.md) for the fork overlay and maintainer release
architecture. Some inherited documents still use the upstream Ghostty name
where they describe the shared core.

## Configuration

FLASH-Ghostty keeps its runtime state separate from the official Ghostty app.
On macOS, the primary user configuration is:

```text
~/Library/Application Support/com.flashghostty.app/config.ghostty
```

The product-scoped fallback is:

```text
$XDG_CONFIG_HOME/flash-ghostty/config.ghostty
```

When `XDG_CONFIG_HOME` is unset, its usual fallback is
`~/.config/flash-ghostty/config.ghostty`. Caches, themes, crash state, and SSH
state also use the `flash-ghostty` filesystem namespace rather than Ghostty's.

Product defaults are loaded before the user configuration, so user settings
win. The current FLASH defaults enable window state saving, select the session
sidebar titlebar, and keep Claude Code on terminal-owned scrollback. To restore
Claude Code's alternate screen, add this to the user configuration:

```text
env = CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=
```

The general [Ghostty configuration
documentation](https://ghostty.org/docs/config) remains useful for settings
inherited from the shared core; use the FLASH-specific paths above when editing
this fork's configuration.

## Validation

The `FLASH-Ghostty Branch Validation` workflow checks the product overlay and
runs the shared Zig and `libghostty-vt` tests, strict Swift lint, macOS unit
tests, and four critical end-to-end UI suites:

- session sidebar;
- file browser;
- surface navigation; and
- session restoration.

It also builds a universal Release-configuration app for `arm64` and `x86_64`
and verifies the FLASH-Ghostty bundle identity. Developer ID signing and
notarization are intentionally outside normal branch validation. CI currently
pins Xcode 26.6, Nushell 0.115.1, and SwiftLint 0.65.1 in addition to the Zig
version declared by the repository.

## Relationship to Ghostty

FLASH-Ghostty is not an official Ghostty release and is not maintained by the
Ghostty project. It is a downstream fork that aims to keep the product-specific
workspace layer isolated enough to continue incorporating upstream Ghostty
work.

- Upstream project: [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)
- Upstream documentation: [ghostty.org/docs](https://ghostty.org/docs)

FLASH-specific session, file-browser, navigation, restoration, and product
identity behavior belongs to this fork rather than to the upstream Ghostty
project.

## Contributing

Use this repository's pull requests for FLASH-specific contributions, and use
[AGENTS.md](AGENTS.md) for the expected development commands. Changes to
FLASH-owned macOS features generally live under
`macos/Sources/Flash/` or the session workspace views, while reusable terminal
behavior remains in the shared Zig core.

[CONTRIBUTING.md](CONTRIBUTING.md) and [HACKING.md](HACKING.md) are inherited
from Ghostty and remain useful references for shared-core conventions. Their
upstream issue links, vouching process, and maintainer policies describe the
Ghostty project, not the contribution process for this fork.

## License

FLASH-Ghostty is distributed under the [MIT License](LICENSE). The repository
retains Ghostty's copyright notices and upstream attribution.
