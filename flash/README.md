# FLASH-Ghostty fork overlay

This directory owns configuration that belongs to the fork rather than to
Ghostty's shared core.

- `product.env` is the shell/CI product manifest.
- `../macos/Configurations/FlashGhostty.*.xcconfig` contains Xcode product
  identity by build configuration. The Xcode project attaches these files at
  project level for Debug, Release, and ReleaseLocal.
- `../macos/FlashGhostty-Info.plist`, `../macos/FlashGhostty.sdef`, and
  `../macos/Sources/App/FlashMainMenu.xib` isolate the fork's bundle metadata,
  scripting dictionary, and main menu from their upstream counterparts.
- `../macos/Sources/Flash/Configuration/FlashGhosttyDefaults.ghostty` contains
  product defaults loaded before the user's configuration. User values win.
- `verify-product-overlay.sh` rejects drift between the manifest, Xcode
  overlay, Swift runtime profile, and default config.

FLASH-Ghostty keeps runtime state separate from official Ghostty. On macOS its
primary configuration is
`~/Library/Application Support/com.flashghostty.app/config.ghostty`; the
product-scoped XDG fallback is `$XDG_CONFIG_HOME/flash-ghostty/config.ghostty`.
Caches, themes, crash state, and SSH state use the same `flash-ghostty`
filesystem namespace.

The project selects the matching overlay automatically. CI also passes it
explicitly as a drift check:

```sh
macos/build.nu \
  --configuration Debug \
  --xcconfig "$PWD/macos/Configurations/FlashGhostty.Debug.xcconfig" \
  --action build
```

Official Ghostty release workflows and helper scripts remain unchanged. The
fork uses `.github/workflows/flash-release.yml`; update distribution stays
disabled until FLASH-Ghostty owns signing and update-feed infrastructure.
