import Darwin
import Foundation

/// Filesystem identity for one directory entry at a point in time.
///
/// Keep this independent from either terminal links or file-browser rows so
/// every Launch Services entry point can use the same replacement check.
struct FlashFilesystemIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let generation: UInt32
    let birthtimeSeconds: Int64
    let birthtimeNanoseconds: Int64

    init(
        device: UInt64,
        inode: UInt64,
        generation: UInt32,
        birthtimeSeconds: Int64,
        birthtimeNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.generation = generation
        self.birthtimeSeconds = birthtimeSeconds
        self.birthtimeNanoseconds = birthtimeNanoseconds
    }

    init?(url: URL) {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else { return nil }
        self.init(metadata: metadata)
    }

    init(metadata: stat) {
        self.init(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            generation: metadata.st_gen,
            birthtimeSeconds: Int64(metadata.st_birthtimespec.tv_sec),
            birthtimeNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec)
        )
    }
}

/// Mutation-sensitive identity for an application executable.
///
/// Ordinary documents intentionally use `FlashFilesystemIdentity`, so editing
/// a file while its terminal menu is open does not invalidate a reveal or open
/// action. An Open With application's executable is different: an in-place
/// rewrite keeps its inode, generation, and birth time while changing the code
/// that receives the document. Capture metadata changed by both content and
/// permission mutations for executable entries only.
struct FlashApplicationExecutableIdentity: Equatable, Sendable {
    let filesystem: FlashFilesystemIdentity
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64
    let size: Int64
    let mode: UInt32

    init?(url: URL) {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else { return nil }
        filesystem = FlashFilesystemIdentity(metadata: metadata)
        statusChangeSeconds = Int64(metadata.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
        size = Int64(metadata.st_size)
        mode = UInt32(metadata.st_mode)
    }
}

/// A local filesystem target recognized in terminal output.
///
/// Keep resolution separate from AppKit presentation so path behavior can be
/// tested without launching applications or presenting UI.
struct FlashTerminalFileTarget: Equatable, Sendable {
    enum Kind: Hashable, Sendable {
        case regularFile
        case directory
    }

    enum OpenSafety: Equatable, Sendable {
        /// Launch Services may open this target.
        case allowed

        /// The target may be revealed, but opening it could execute code.
        case revealOnly
    }

    /// The spelling selected in terminal output, standardized but with
    /// symlinks intact. Finder should reveal this URL.
    let lexicalURL: URL

    /// The effective target after resolving symlinks. Applications should
    /// only receive this URL after revalidating its safety.
    let canonicalURL: URL

    let kind: Kind
    let line: Int?
    let column: Int?
    let openSafety: OpenSafety

    /// Used to reuse Launch Services results for files of the same type. This
    /// value is collected during background resolution, never on the UI thread.
    let contentTypeIdentifier: String?

    /// The lexical identity catches a replaced file or symlink. The canonical
    /// identity separately catches replacement of the symlink destination.
    private let lexicalIdentity: FlashFilesystemIdentity
    private let canonicalIdentity: FlashFilesystemIdentity

    init?(
        lexicalURL: URL,
        canonicalURL: URL,
        kind: Kind,
        line: Int?,
        column: Int?,
        openSafety: OpenSafety,
        contentTypeIdentifier: String?
    ) {
        guard
            let lexicalIdentity = FlashFilesystemIdentity(url: lexicalURL),
            let canonicalIdentity = FlashFilesystemIdentity(url: canonicalURL)
        else { return nil }

        self.lexicalURL = lexicalURL
        self.canonicalURL = canonicalURL
        self.kind = kind
        self.line = line
        self.column = column
        self.openSafety = openSafety
        self.contentTypeIdentifier = contentTypeIdentifier
        self.lexicalIdentity = lexicalIdentity
        self.canonicalIdentity = canonicalIdentity
    }

    func hasSameFilesystemIdentity(as other: Self) -> Bool {
        lexicalIdentity == other.lexicalIdentity &&
            canonicalIdentity == other.canonicalIdentity
    }

    func hasLexicalFilesystemIdentity(_ identity: FlashFilesystemIdentity) -> Bool {
        lexicalIdentity == identity
    }
}

enum FlashTerminalFileTargetResolver {
    /// Resolve a terminal link as a local file or directory.
    ///
    /// Relative paths are resolved only against the terminal's working
    /// directory. They must never fall back to the app process directory.
    static func resolve(
        _ rawValue: String,
        workingDirectory: String?,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> FlashTerminalFileTarget? {
        guard
            !rawValue.isEmpty,
            !containsUnsafeCharacters(rawValue),
            let path = localPath(from: rawValue),
            !containsUnsafeCharacters(path)
        else { return nil }

        for candidate in pathCandidates(path) {
            guard let lexicalURL = lexicalURL(
                for: candidate.path,
                workingDirectory: workingDirectory,
                homeDirectory: homeDirectory
            ), !containsUnsafeCharacters(lexicalURL.path) else { continue }

            guard fileManager.fileExists(atPath: lexicalURL.path) else {
                continue
            }

            let canonicalURL = lexicalURL.resolvingSymlinksInPath()
            guard !containsUnsafeCharacters(canonicalURL.path) else {
                continue
            }
            let values: URLResourceValues
            do {
                values = try canonicalURL.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .typeIdentifierKey,
                ])
            } catch {
                continue
            }

            let kind: FlashTerminalFileTarget.Kind
            if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .regularFile
            } else {
                // Devices, sockets, and other special files do not belong in
                // Launch Services or Finder actions sourced from a terminal.
                continue
            }

            let openSafety: FlashTerminalFileTarget.OpenSafety
            let effectiveURL: URL
            switch UntrustedURL(canonicalURL.absoluteString).decision {
            case .allow(let allowedURL) where allowedURL.isFileURL:
                openSafety = .allowed
                effectiveURL = allowedURL

            case .deny(.unsafeFile):
                openSafety = .revealOnly
                effectiveURL = canonicalURL

            default:
                continue
            }

            return FlashTerminalFileTarget(
                lexicalURL: lexicalURL,
                canonicalURL: effectiveURL,
                kind: kind,
                line: kind == .regularFile ? candidate.line : nil,
                column: kind == .regularFile ? candidate.column : nil,
                openSafety: openSafety,
                contentTypeIdentifier: values.typeIdentifier
            )
        }

        return nil
    }

    /// Revalidate a menu target without allowing location-suffix parsing to
    /// retarget the action if the original filesystem entry disappeared.
    static func revalidate(
        _ previous: FlashTerminalFileTarget,
        fileManager: FileManager = .default
    ) -> FlashTerminalFileTarget? {
        guard let current = resolve(
            previous.lexicalURL.absoluteString,
            workingDirectory: nil,
            fileManager: fileManager
        ) else { return nil }

        guard
            current.lexicalURL.standardizedFileURL.path ==
                previous.lexicalURL.standardizedFileURL.path,
            current.canonicalURL.standardizedFileURL.path ==
                previous.canonicalURL.standardizedFileURL.path,
            current.kind == previous.kind,
            current.hasSameFilesystemIdentity(as: previous)
        else { return nil }

        return current
    }

    /// True when a value should be treated as a local-path attempt instead of
    /// being retried against the app process working directory.
    static func isPotentialLocalPath(_ rawValue: String) -> Bool {
        linkClassification(rawValue) != .nonFileURL
    }

    /// Whether a scheme-like value should return to the normal URL opener if
    /// no same-named local target exists in the session working directory.
    static func shouldRetryAsURLAfterLocalMiss(_ rawValue: String) -> Bool {
        linkClassification(rawValue) == .ambiguous
    }
}

private extension FlashTerminalFileTargetResolver {
    struct PathCandidate {
        let path: String
        let line: Int?
        let column: Int?
    }

    enum LinkClassification {
        case localPath
        case nonFileURL
        case ambiguous
    }

    static let knownNonFileSchemes: Set<String> = [
        "gemini",
        "git",
        "gopher",
        "http",
        "https",
        "ipfs",
        "ipns",
        "magnet",
        "mailto",
        "news",
        "ssh",
        "tel",
    ]

    static func localPath(from rawValue: String) -> String? {
        if rawValue.lowercased().hasPrefix("file:") {
            guard
                let url = URL(string: rawValue),
                url.isFileURL,
                url.query == nil,
                url.fragment == nil,
                url.path.hasPrefix("/")
            else { return nil }

            if let host = url.host,
               !host.isEmpty,
               host.caseInsensitiveCompare("localhost") != .orderedSame {
                return nil
            }

            return url.path
        }

        guard linkClassification(rawValue) != .nonFileURL else { return nil }
        return rawValue
    }

    static func linkClassification(_ value: String) -> LinkClassification {
        if value.lowercased().hasPrefix("file:") { return .localPath }
        guard let colon = value.firstIndex(of: ":") else { return .localPath }
        let scheme = value[..<colon].lowercased()

        // The default matcher has a fixed list of URL schemes. Checking that
        // list avoids misclassifying compiler locations such as
        // `foo.swift:42` as Foundation URL schemes.
        if knownNonFileSchemes.contains(scheme) { return .nonFileURL }

        // OSC 8 may contain custom hierarchical schemes not present in the
        // default matcher. They are never local file paths.
        if value[value.index(after: colon)...].hasPrefix("//") {
            return .nonFileURL
        }

        // Preserve opaque custom URIs such as `vscode:open`. Foundation also
        // interprets compiler locations as opaque URLs. A dotted location is
        // file-like; an undotted numeric suffix is ambiguous and gets a local
        // existence check before the URL fallback.
        guard isValidURLScheme(scheme) else { return .localPath }
        if locationSuffix(in: value) != nil {
            return scheme.contains(".") ? .localPath : .ambiguous
        }
        return .nonFileURL
    }

    static func isValidURLScheme(_ value: String) -> Bool {
        guard let first = value.utf8.first, isASCIILetter(first) else {
            return false
        }

        return value.utf8.dropFirst().allSatisfy { byte in
            isASCIILetter(byte) || (0x30...0x39).contains(byte) ||
                byte == 0x2B || byte == 0x2D || byte == 0x2E
        }
    }

    static func isASCIILetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    static func pathCandidates(_ path: String) -> [PathCandidate] {
        var result = [PathCandidate(path: path, line: nil, column: nil)]
        guard let location = locationSuffix(in: path) else { return result }
        result.append(location)
        return result
    }

    static func locationSuffix(in path: String) -> PathCandidate? {
        guard let lastColon = path.lastIndex(of: ":") else { return nil }
        let trailing = path[path.index(after: lastColon)...]
        guard let trailingValue = positiveInteger(trailing) else { return nil }

        let beforeTrailing = path[..<lastColon]
        guard !beforeTrailing.isEmpty else { return nil }

        if let previousColon = beforeTrailing.lastIndex(of: ":"),
           let line = positiveInteger(beforeTrailing[beforeTrailing.index(after: previousColon)...]) {
            let base = String(beforeTrailing[..<previousColon])
            guard
                !base.isEmpty,
                !hasNumericSuffix(base)
            else { return nil }

            return PathCandidate(
                path: base,
                line: line,
                column: trailingValue
            )
        }

        let base = String(beforeTrailing)
        guard !base.isEmpty else { return nil }
        return PathCandidate(path: base, line: trailingValue, column: nil)
    }

    static func hasNumericSuffix(_ value: String) -> Bool {
        guard let colon = value.lastIndex(of: ":") else { return false }
        return positiveInteger(value[value.index(after: colon)...]) != nil
    }

    static func positiveInteger(_ value: Substring) -> Int? {
        guard let result = Int(value), result > 0 else { return nil }
        return result
    }

    static func lexicalURL(
        for path: String,
        workingDirectory: String?,
        homeDirectory: String
    ) -> URL? {
        guard let expandedPath = expand(
            path,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory
        ) else { return nil }

        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }

        guard
            let workingDirectory,
            !workingDirectory.isEmpty,
            workingDirectory.hasPrefix("/")
        else { return nil }

        let baseURL = URL(
            fileURLWithPath: workingDirectory,
            isDirectory: true
        )
        return URL(
            fileURLWithPath: expandedPath,
            relativeTo: baseURL
        ).standardizedFileURL
    }

    static func expand(
        _ path: String,
        workingDirectory: String?,
        homeDirectory: String
    ) -> String? {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") {
            return homeDirectory + "/" + path.dropFirst(2)
        }
        if path.hasPrefix("~") {
            // User-home expansion (`~other`) is deliberately unsupported.
            return nil
        }

        if path == "$HOME" { return homeDirectory }
        if path.hasPrefix("$HOME/") {
            return homeDirectory + "/" + path.dropFirst(6)
        }

        if path == "$PWD" { return workingDirectory }
        if path.hasPrefix("$PWD/") {
            guard let workingDirectory else { return nil }
            return workingDirectory + "/" + path.dropFirst(5)
        }

        // Never invoke a shell to expand arbitrary variables supplied by
        // terminal output.
        if path.hasPrefix("$") { return nil }
        return path
    }

    static func containsUnsafeCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x00...0x1F, 0x7F...0x9F:
                return true
            case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069:
                return true
            case 0x2028...0x2029, 0x2060, 0xFEFF:
                return true
            default:
                return false
            }
        }
    }
}
