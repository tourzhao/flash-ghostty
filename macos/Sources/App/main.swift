import AppKit
import Cocoa
import GhosttyKit

/// Proof that this process redirected AppKit's outer restoration archive before
/// `NSApplicationMain` began. The fileprivate initializer keeps this authority
/// at the pre-main call site while other files may only carry the value.
struct AppKitOuterArchiveIsolation: Equatable, Sendable {
    fileprivate init() {}
}

// A `-e` process is a one-shot command window, not a replacement interactive
// workspace. A hosted unit-test process must likewise leave the developer's
// workspace untouched. Install this before AppKit initializes and retain the
// resulting proof for the launch-wide restoration coordinator.
let appKitOuterArchiveIsolation: AppKitOuterArchiveIsolation? = {
    guard CommandLinePersistencePolicy.installIfNeeded(
        arguments: CommandLine.arguments,
        isUnitTestHost: SessionRestorationProcessRole.isUnitTestHost()
    ) else { return nil }

    return AppKitOuterArchiveIsolation()
}()
// Force the global initializer at this exact top-level point rather than rely
// on the first read from AppDelegate after NSApplicationMain has begun.
_ = appKitOuterArchiveIsolation

// Initialize Ghostty global state. We do this once right away because the
// CLI APIs require it and it lets us ensure it is done immediately for the
// rest of the app.
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    Ghostty.logger.critical("ghostty_init failed")

    // We also write to stderr if this is executed from the CLI or zig run
    switch Ghostty.launchSource {
    case .cli, .zig_run:
        let stderrHandle = FileHandle.standardError
        stderrHandle.write(
            "\(FlashGhosttyProductProfile.displayName) failed to initialize! " +
            "If you're executing \(FlashGhosttyProductProfile.displayName) from the command line\n" +
            "then this is usually because an invalid action or multiple actions were specified.\n" +
            "Actions start with the `+` character.\n\n" +
            "View all available actions by running `ghostty +help`.\n")
        exit(1)

    case .app:
        // For the app we exit immediately. We should handle this case more
        // gracefully in the future.
        exit(1)
    }
}

// This will run the CLI action and exit if one was specified. A CLI
// action is a command starting with a `+`, such as `ghostty +boo`.
ghostty_cli_try_action()

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
