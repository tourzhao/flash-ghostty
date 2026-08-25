#!/usr/bin/env nu

# Build the macOS Ghostty app using xcodebuild with a clean environment
# to avoid Nix shell interference (NIX_LDFLAGS, NIX_CFLAGS_COMPILE, etc.).

def main [
    --scheme: string = "Ghostty"       # Xcode scheme (Ghostty, DockTilePlugin)
    --configuration: string = "Debug"  # Build configuration (Debug, Release, ReleaseLocal)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
    --include-ui-tests                  # Opt in to permission-sensitive UI regression tests
    --only-testing: string = ""        # Restrict tests to an XCTest target, class, or method
    --xcconfig: string = ""             # Optional Xcode configuration overlay
] {
    if $include_ui_tests and $configuration != "Debug" {
        error make {
            msg: "--include-ui-tests is restricted to Debug so Release defaults remain untouched"
        }
    }

    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let build_dir = ($env.FILE_PWD | path join "build")

    # Skip UI tests for CLI-based invocations because it requires
    # special permissions.
    let skip_testing = if $action == "test" and not $include_ui_tests {
        [-skip-testing GhosttyUITests]
    } else {
        []
    }

    # UI test runners do not reliably inherit the parent shell environment.
    # A compile-time condition makes the opt-in observable inside the isolated
    # XCTest process and prevents a misleading "0 tests" success.
    let ui_test_settings = if $include_ui_tests {
        ["OTHER_SWIFT_FLAGS=-DGHOSTTY_RUN_UI_TESTS"]
    } else {
        []
    }

    let only_testing_args = if ($only_testing | is-empty) {
        []
    } else {
        [-only-testing $only_testing]
    }

    let xcconfig_args = if ($xcconfig | is-empty) {
        []
    } else {
        [-xcconfig $xcconfig]
    }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        ...$xcconfig_args
        $"SYMROOT=($build_dir)"
        ...$ui_test_settings
        ...$skip_testing
        ...$only_testing_args
        $action)
}
