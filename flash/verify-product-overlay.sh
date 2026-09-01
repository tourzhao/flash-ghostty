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
branch_workflow="$repository_root/.github/workflows/flash-branch-validate.yml"
release_workflow="$repository_root/.github/workflows/flash-release.yml"
upstream_publish_workflow="$repository_root/.github/workflows/publish-tag.yml"
upstream_release_tag_workflow="$repository_root/.github/workflows/release-tag.yml"
upstream_release_tip_workflow="$repository_root/.github/workflows/release-tip.yml"

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
require_literal "$upstream_publish_workflow" "if: github.repository == 'ghostty-org/ghostty'"
require_literal "$upstream_release_tag_workflow" "if: github.repository == 'ghostty-org/ghostty'"
require_literal "$upstream_release_tip_workflow" "github.repository == 'ghostty-org/ghostty' &&"
require_literal "$branch_workflow" '    shell: bash'
require_literal "$release_workflow" '    shell: bash'
require_literal "$release_workflow" '--sign "$signing_identity_sha1"'
require_literal "$release_workflow" '--extract-certificates "$certificate_prefix"'
require_literal "$release_workflow" 'if [[ "$actual_certificate_sha1" != "$signing_identity_sha1" ]]; then'
require_literal "$release_workflow" 'if [[ "$actual_certificate_sha256" != "$FLASH_EXPECTED_CERTIFICATE_SHA256" ]]; then'
require_literal "$release_workflow" 'if [[ "$embedded_leaf_sha256" != "$FLASH_EXPECTED_CERTIFICATE_SHA256" ]]; then'
require_literal "$release_workflow" 'unsigned_run_attempt: ${{ steps.signing_input.outputs.run_attempt }}'
require_literal "$release_workflow" 'unsigned_cache_key: ${{ steps.signing_input.outputs.cache_key }}'
require_literal "$release_workflow" "printf 'run_attempt=%s\\n' \"\$GITHUB_RUN_ATTEMPT\" >> \"\$GITHUB_OUTPUT\""
require_literal "$release_workflow" "printf 'cache_key=%s\\n' \"\$cache_key\" >> \"\$GITHUB_OUTPUT\""
require_literal "$release_workflow" 'cache_key="flash-unsigned-macos-${GITHUB_RUN_ID}-${full_commit}-${GITHUB_RUN_ATTEMPT}"'
require_literal "$release_workflow" 'uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0'
require_literal "$release_workflow" 'uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0'
require_literal "$release_workflow" 'path: unsigned-signing-input'
require_literal "$release_workflow" 'lookup-only: true'
require_literal "$release_workflow" 'name: flash-ghostty-${{ needs.validate.outputs.version }}-unsigned-${{ github.run_id }}-${{ steps.signing_input.outputs.run_attempt }}'
require_literal "$release_workflow" "key: \${{ needs['build-macos'].outputs.unsigned_cache_key }}"
require_literal "$release_workflow" 'fail-on-cache-miss: true'
require_literal "$release_workflow" 'SAVED_UNSIGNED_CACHE_HIT: ${{ steps.unsigned_cache_lookup.outputs.cache-hit }}'
require_literal "$release_workflow" 'SAVED_UNSIGNED_CACHE_KEY: ${{ steps.unsigned_cache_lookup.outputs.cache-matched-key }}'
require_literal "$release_workflow" 'test "$SAVED_UNSIGNED_CACHE_HIT" = true'
require_literal "$release_workflow" 'test "$SAVED_UNSIGNED_CACHE_KEY" = "$EXPECTED_UNSIGNED_CACHE_KEY"'
require_literal "$release_workflow" "EXPECTED_UNSIGNED_RUN_ATTEMPT: \${{ needs['build-macos'].outputs.unsigned_run_attempt }}"
require_literal "$release_workflow" "EXPECTED_UNSIGNED_CACHE_KEY: \${{ needs['build-macos'].outputs.unsigned_cache_key }}"
require_literal "$release_workflow" 'RESTORED_UNSIGNED_CACHE_KEY: ${{ steps.unsigned_cache.outputs.cache-matched-key }}'
require_literal "$release_workflow" '[[ "$EXPECTED_UNSIGNED_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]]'
require_literal "$release_workflow" '"flash-unsigned-macos-${GITHUB_RUN_ID}-${GITHUB_SHA}-${EXPECTED_UNSIGNED_RUN_ATTEMPT}"'
require_literal "$release_workflow" 'test "$(manifest_value github_run_attempt)" = "$EXPECTED_UNSIGNED_RUN_ATTEMPT"'
require_literal "$release_workflow" 'test "$RESTORED_UNSIGNED_CACHE_KEY" = "$EXPECTED_UNSIGNED_CACHE_KEY"'

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
