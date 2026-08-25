#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/flash/product.env"

shared_xcconfig="$repository_root/macos/Configurations/FlashGhostty.Shared.xcconfig"
debug_xcconfig="$repository_root/macos/Configurations/FlashGhostty.Debug.xcconfig"
swift_profile="$repository_root/macos/Sources/App/FlashGhosttyProductProfile.swift"
defaults_overlay="$repository_root/macos/Sources/Flash/Configuration/FlashGhosttyDefaults.ghostty"
fork_plist="$repository_root/macos/FlashGhostty-Info.plist"
fork_sdef="$repository_root/macos/FlashGhostty.sdef"
fork_main_menu="$repository_root/macos/Sources/App/FlashMainMenu.xib"

require_literal() {
    file=$1
    literal=$2
    if ! grep -Fq -- "$literal" "$file"; then
        echo "identity drift: '$literal' is missing from $file" >&2
        exit 1
    fi
}

require_literal "$shared_xcconfig" "FLASH_GHOSTTY_APP_DISPLAY_NAME = $FLASH_GHOSTTY_DISPLAY_NAME"
require_literal "$shared_xcconfig" "FLASH_GHOSTTY_APP_BUNDLE_IDENTIFIER = $FLASH_GHOSTTY_RELEASE_BUNDLE_ID"
require_literal "$shared_xcconfig" "FLASH_GHOSTTY_FILESYSTEM_NAMESPACE = $FLASH_GHOSTTY_FILESYSTEM_NAMESPACE"
require_literal "$shared_xcconfig" "FLASH_GHOSTTY_MAIN_NIB = FlashMainMenu"
require_literal "$debug_xcconfig" "FLASH_GHOSTTY_APP_BUNDLE_IDENTIFIER = $FLASH_GHOSTTY_DEBUG_BUNDLE_ID"
require_literal "$swift_profile" "static let displayName = \"$FLASH_GHOSTTY_DISPLAY_NAME\""
require_literal "$swift_profile" "static let releaseBundleIdentifier = \"$FLASH_GHOSTTY_RELEASE_BUNDLE_ID\""
require_literal "$swift_profile" "static let debugBundleIdentifier = \"$FLASH_GHOSTTY_DEBUG_BUNDLE_ID\""
require_literal "$swift_profile" "static let filesystemNamespace = \"$FLASH_GHOSTTY_FILESYSTEM_NAMESPACE\""
require_literal "$defaults_overlay" "macos-custom-icon = ~/.config/$FLASH_GHOSTTY_FILESYSTEM_NAMESPACE/$FLASH_GHOSTTY_DISPLAY_NAME.icns"
require_literal "$fork_plist" '<string>$(FLASH_GHOSTTY_APP_DISPLAY_NAME)</string>'
require_literal "$fork_plist" '<string>$(FLASH_GHOSTTY_APP_BUNDLE_IDENTIFIER).surface-id</string>'
require_literal "$fork_plist" '<string>FlashGhostty.sdef</string>'
require_literal "$fork_sdef" '<dictionary title="FLASH-Ghostty Scripting Dictionary">'
require_literal "$fork_main_menu" 'menuItem title="FLASH-Ghostty"'
require_literal "$fork_main_menu" 'action selector="toggleSessionSidebar:"'

if [ "$FLASH_GHOSTTY_UPDATE_ENABLED" != false ]; then
    echo "update publishing must remain disabled until product-owned signing is configured" >&2
    exit 1
fi

if grep -Eq '(^|[[:space:]])(SUFeedURL|SUPublicEDKey)[[:space:]]*=' "$shared_xcconfig"; then
    echo "fork overlay must not inherit the official Ghostty update trust root" >&2
    exit 1
fi

if grep -Eq '<key>(SUFeedURL|SUPublicEDKey)</key>' "$fork_plist"; then
    echo "fork plist must not inherit the official Ghostty update trust root" >&2
    exit 1
fi

echo "FLASH-Ghostty product overlay is internally consistent."
