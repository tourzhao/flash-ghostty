//! Build options, available at comptime. Used to configure features. This
//! will reproduce some of the fields from builtin and build_options just
//! so we can limit the amount of imports we need AND give us the ability
//! to shim logic and values into them later.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const assert = std.debug.assert;
const apprt = @import("apprt.zig");
const font = @import("font/main.zig");
const rendererpkg = @import("renderer.zig");
const BuildConfig = @import("build/Config.zig");

pub const ReleaseChannel = BuildConfig.ReleaseChannel;

/// The semantic version of this build.
pub const version = options.app_version;
pub const version_string = options.app_version_string;

/// The release channel for this build.
pub const release_channel = std.meta.stringToEnum(ReleaseChannel, @tagName(options.release_channel)).?;

/// The optimization mode as a string.
pub const mode_string = mode: {
    const m = @tagName(builtin.mode);
    if (std.mem.lastIndexOfScalar(u8, m, '.')) |i| break :mode m[i..];
    break :mode m;
};

/// The artifact we're producing. This can be used to determine if we're
/// building a standalone exe, an embedded lib, etc.
pub const artifact = Artifact.detect();

/// Our build configuration. We re-export a lot of these back at the
/// top-level so its a bit cleaner to use throughout the code. See the doc
/// comments in BuildConfig for details on each.
const config = BuildConfig.fromOptions();
pub const exe_entrypoint = config.exe_entrypoint;
pub const flatpak = options.flatpak;
pub const snap = options.snap;
pub const app_runtime: apprt.Runtime = config.app_runtime;
pub const font_backend: font.Backend = config.font_backend;
pub const renderer: rendererpkg.Backend = config.renderer;
pub const i18n: bool = config.i18n;

/// The bundle ID for the FLASH-Ghostty app. This is the root namespace for
/// macOS Application Support, caches, and unified logging.
///
/// On macOS, this must match the App bundle ID. We can get that dynamically
/// via an API but I don't want to pay the cost of that at runtime.
///
/// On GTK, this should match the various folders with resources.
///
/// The Zig XCFramework can be reused across Xcode configurations, so the
/// macOS lower-level namespace intentionally remains stable. Xcode's Debug
/// suffix still isolates Cocoa defaults, while Zig config/cache/log data uses
/// the FLASH release root. Other platforms retain upstream Ghostty identity.
pub const bundle_id = if (builtin.os.tag == .macos)
    "com.flashghostty.app"
else
    "com.mitchellh.ghostty";

/// Filesystem namespace used in XDG config, cache, and state directories.
/// On macOS this must never be `ghostty`: FLASH-Ghostty is a separate product
/// and must not silently consume or overwrite the official application's data.
pub const filesystem_namespace = if (builtin.os.tag == .macos)
    "flash-ghostty"
else
    "ghostty";

test "FLASH-Ghostty product namespaces are isolated" {
    if (builtin.os.tag == .macos) {
        try std.testing.expectEqualStrings("com.flashghostty.app", bundle_id);
        try std.testing.expectEqualStrings("flash-ghostty", filesystem_namespace);
    } else {
        try std.testing.expectEqualStrings("com.mitchellh.ghostty", bundle_id);
        try std.testing.expectEqualStrings("ghostty", filesystem_namespace);
    }
}

/// True if we should have "slow" runtime safety checks. The initial motivation
/// for this was terminal page/pagelist integrity checks. These were VERY
/// slow but very thorough. But they made it so slow that the terminal couldn't
/// be used for real work. We'd love to have an option to run a build with
/// safety checks that could be used for real work. This lets us do that.
pub const slow_runtime_safety = std.debug.runtime_safety and switch (builtin.mode) {
    .Debug => true,
    .ReleaseSafe,
    .ReleaseSmall,
    .ReleaseFast,
    => false,
};

pub const Artifact = enum {
    /// Standalone executable
    exe,

    /// Embeddable library
    lib,

    /// The WASM-targeted module.
    wasm_module,

    pub fn detect() Artifact {
        if (builtin.target.cpu.arch.isWasm()) {
            assert(builtin.output_mode == .Obj);
            assert(builtin.link_mode == .Static);
            return .wasm_module;
        }

        return switch (builtin.output_mode) {
            .Exe => .exe,
            .Lib => .lib,
            else => {
                @compileLog(builtin.output_mode);
                @compileError("unsupported artifact output mode");
            },
        };
    }
};

/// True if runtime safety checks are enabled.
pub const is_debug = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};
