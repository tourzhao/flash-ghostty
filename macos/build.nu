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
    --architectures: string = ""        # Optional space-separated Xcode ARCHS override
    --build-dir: string = ""             # Optional Xcode products directory (defaults to macos/build)
    --locked-packages                    # Require versions from the checked-in Package.resolved
] {
    if $include_ui_tests and $configuration != "Debug" {
        error make {
            msg: "--include-ui-tests is restricted to Debug so Release defaults remain untouched"
        }
    }

    if $include_ui_tests and $action != "test" {
        error make {
            msg: "--include-ui-tests is only valid with --action test"
        }
    }

    if not ($only_testing | is-empty) and $action != "test" {
        error make {
            msg: "--only-testing is only valid with --action test"
        }
    }

    if ($only_testing | str starts-with "GhosttyUITests") and not $include_ui_tests {
        error make {
            msg: "GhosttyUITests requires --include-ui-tests so the suite cannot silently skip"
        }
    }

    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let resolved_build_dir = if ($build_dir | is-empty) {
        $env.FILE_PWD | path join "build"
    } else {
        $build_dir | path expand
    }
    let derived_data_dir = $resolved_build_dir | path join "DerivedData"

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
    let ui_test_run_id = (
        $env.FLASH_GHOSTTY_UI_TEST_RUN_ID?
        # PIDs are recycled, while AppKit Saved Application State outlives the
        # test process. A UUID prevents an interrupted historical UI run from
        # contaminating a later local invocation.
        | default (random uuid)
    )
    if $include_ui_tests and $ui_test_run_id !~ '^[A-Za-z0-9-]+$' {
        error make {
            msg: "FLASH_GHOSTTY_UI_TEST_RUN_ID must contain only letters, digits, or hyphens"
        }
    }
    let ui_test_bundle_identifier = $"com.flashghostty.app.debug.ui-tests.run-($ui_test_run_id)"
    let ui_test_settings = if $include_ui_tests {
        [
            "OTHER_SWIFT_FLAGS=-DGHOSTTY_RUN_UI_TESTS"
            # Never let state-restoration UI tests share AppKit's saved-state
            # domain with a developer build or an interrupted prior test run.
            $"FLASH_GHOSTTY_APP_BUNDLE_IDENTIFIER=($ui_test_bundle_identifier)"
        ]
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

    let architecture_list = (
        $architectures
        | split row --regex '\s+'
        | where {|architecture| not ($architecture | is-empty)}
    )
    let invalid_architectures = (
        $architecture_list
        | where {|architecture| $architecture !~ '^[A-Za-z0-9_]+$'}
    )
    if not ($invalid_architectures | is-empty) {
        error make {
            msg: $"--architectures contains invalid names: ($invalid_architectures | str join ', ')"
        }
    }

    let architecture_settings = if ($architecture_list | is-empty) {
        []
    } else {
        [$"ARCHS=($architecture_list | str join ' ')" "ONLY_ACTIVE_ARCH=NO"]
    }

    let package_resolution_args = if $locked_packages {
        [-onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates]
    } else {
        []
    }

    # The Xcode project has an explicit CI fast path for its SwiftLint build
    # phase. Preserve only this runner-owned marker through the clean
    # environment; lint is run as a separate strict workflow gate.
    let github_actions_setting = if ($env.GITHUB_ACTIONS? | default "" | is-empty) {
        []
    } else {
        [$"GITHUB_ACTIONS=($env.GITHUB_ACTIONS)"]
    }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        ...$github_actions_setting
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        -derivedDataPath $derived_data_dir
        ...$xcconfig_args
        ...$package_resolution_args
        $"SYMROOT=($resolved_build_dir)"
        ...$architecture_settings
        ...$ui_test_settings
        ...$skip_testing
        ...$only_testing_args
        $action)
}
