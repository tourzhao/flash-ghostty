import Testing
@testable import Ghostty

@Suite
struct CommandLineOpenFileFilterTests {
    @Test func executeLaunchInstallsVolatilePersistenceOverride() {
        let defaults = UserDefaults.standard
        let domainName = "CommandLinePersistencePolicyTests-\(UUID())"
        defer { defaults.removeVolatileDomain(forName: domainName) }
        defaults.setVolatileDomain(["ExistingArgument": "kept"], forName: domainName)

        let installed = CommandLinePersistencePolicy.installIfNeeded(
            arguments: ["ghostty", "-e", "echo", "hello"],
            defaults: defaults,
            argumentDomainName: domainName
        )

        #expect(installed)
        let domain = defaults.volatileDomain(forName: domainName)
        #expect(domain["ExistingArgument"] as? String == "kept")
        #expect(domain[CommandLinePersistencePolicy.ignoreStateKey] as? Bool == true)
    }

    @Test func interactiveLaunchDoesNotInstallPersistenceOverride() {
        let defaults = UserDefaults.standard
        let domainName = "CommandLinePersistencePolicyTests-\(UUID())"
        defer { defaults.removeVolatileDomain(forName: domainName) }

        let installed = CommandLinePersistencePolicy.installIfNeeded(
            arguments: ["ghostty"],
            defaults: defaults,
            argumentDomainName: domainName
        )

        #expect(!installed)
        #expect(defaults.volatileDomain(forName: domainName).isEmpty)
    }

    @Test func unitTestHostInstallsVolatilePersistenceOverride() {
        let defaults = UserDefaults.standard
        let domainName = "CommandLinePersistencePolicyTests-\(UUID())"
        defer { defaults.removeVolatileDomain(forName: domainName) }

        let installed = CommandLinePersistencePolicy.installIfNeeded(
            arguments: ["ghostty"],
            isUnitTestHost: true,
            defaults: defaults,
            argumentDomainName: domainName
        )

        #expect(installed)
        #expect(
            defaults.volatileDomain(forName: domainName)[
                CommandLinePersistencePolicy.ignoreStateKey
            ] as? Bool == true
        )
    }

    @Test func hostedUnitTestProcessWasIsolatedBeforeAppKitStarted() {
        #expect(SessionRestorationProcessRole.isUnitTestHost())
        #expect(appKitOuterArchiveIsolation != nil)
        #expect(
            UserDefaults.standard.volatileDomain(
                forName: UserDefaults.argumentDomain
            )[CommandLinePersistencePolicy.ignoreStateKey] as? Bool == true
        )
    }

    @Test func requiresExecuteFlag() {
        let filter = CommandLineOpenFileFilter(
            arguments: ["ghostty", "/tmp/file.txt"],
            workingDirectory: "/tmp",
            fileExists: { _ in true }
        )

        #expect(!filter.hasExecuteCommand)
        #expect(!filter.shouldIgnore("/tmp/file.txt"))
    }

    @Test func ignoresExistingPathsAfterExecuteFlag() {
        let existing: Set<String> = [
            "/usr/bin/vim",
            "/tmp/project/file.txt",
            "/tmp/other.txt",
        ]
        let filter = CommandLineOpenFileFilter(
            arguments: [
                "ghostty",
                "/tmp/before.txt",
                "-e",
                "/usr/bin/vim",
                "./file.txt",
                "../other.txt",
                "missing.txt",
            ],
            workingDirectory: "/tmp/project",
            fileExists: { existing.contains($0) }
        )

        #expect(filter.hasExecuteCommand)
        #expect(!filter.shouldIgnore("/tmp/before.txt"))
        #expect(filter.shouldIgnore("/usr/bin/vim"))
        #expect(filter.shouldIgnore("/tmp/project/file.txt"))
        #expect(filter.shouldIgnore("/tmp/other.txt"))
        #expect(!filter.shouldIgnore("/tmp/project/missing.txt"))
    }

    @Test func ignoresEachPathOnce() {
        let filter = CommandLineOpenFileFilter(
            arguments: ["ghostty", "-e", "./file.txt"],
            workingDirectory: "/tmp/project",
            fileExists: { $0 == "/tmp/project/file.txt" }
        )

        #expect(filter.shouldIgnore("./file.txt"))
        #expect(!filter.shouldIgnore("/tmp/project/file.txt"))
    }

    @Test func preservesUnrelatedOpenFileRequests() {
        let filter = CommandLineOpenFileFilter(
            arguments: ["ghostty", "-e", "vim", "/tmp/command-file.txt"],
            workingDirectory: "/tmp",
            fileExists: { $0 == "/tmp/command-file.txt" }
        )

        #expect(!filter.shouldIgnore("/tmp/finder-file.txt"))
        #expect(filter.shouldIgnore("/tmp/command-file.txt"))
    }

    @Test func normalizesFileURLs() {
        let existing: Set<String> = [
            "/tmp/project/file #100%.txt",
            "/tmp/project/directory",
        ]
        let filter = CommandLineOpenFileFilter(
            arguments: [
                "ghostty",
                "-e",
                "command",
                "./file #100%.txt",
                "./directory/",
            ],
            workingDirectory: "/tmp/project",
            fileExists: { existing.contains($0) }
        )

        #expect(filter.shouldIgnore("/tmp/project/file #100%.txt"))
        #expect(filter.shouldIgnore("/tmp/project/directory"))
    }
}
