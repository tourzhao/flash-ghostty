import Darwin
import Foundation

/// Descriptor-relative filesystem primitives shared by the local browser's
/// actor facade and its synchronous helper implementations.
///
/// This namespace is module-internal only so security-sensitive Darwin calls
/// keep one implementation without exposing actor state or validated anchors.
enum FlashFileBrowserDescriptorIO {
    static func entryIdentity(
        named name: String,
        in descriptor: Int32
    ) -> FlashFileBrowserItemIdentity? {
        guard let metadata = entryMetadata(named: name, in: descriptor) else {
            return nil
        }
        return identity(from: metadata)
    }

    static func entryMetadata(
        named name: String,
        in descriptor: Int32,
        followingSymbolicLinks: Bool = false
    ) -> stat? {
        var metadata = stat()
        let flags = followingSymbolicLinks ? 0 : AT_SYMLINK_NOFOLLOW
        let result = name.withCString {
            Darwin.fstatat(descriptor, $0, &metadata, flags)
        }
        guard result == 0 else { return nil }
        return metadata
    }

    static func forEachDirectoryEntry(
        in descriptor: Int32,
        body: (String) throws -> Void
    ) throws {
        // `dup` shares the original directory's open-file-description and
        // therefore its readdir offset. Opening `.` creates an independent
        // description so every scan starts at the beginning and a later
        // security revalidation cannot accidentally begin at EOF.
        let openOutcome = ".".withCString { name in
            callCapturingErrno {
                Darwin.openat(
                    descriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW |
                        O_RESOLVE_BENEATH | O_CLOEXEC
                )
            }
        }
        let streamDescriptor = openOutcome.result
        guard streamDescriptor >= 0 else {
            throw posixError(openOutcome.errorCode)
        }

        var sourceMetadata = stat()
        var streamMetadata = stat()
        let sourceOutcome = callCapturingErrno {
            Darwin.fstat(descriptor, &sourceMetadata)
        }
        guard sourceOutcome.result == 0 else {
            let error = posixError(sourceOutcome.errorCode)
            Darwin.close(streamDescriptor)
            throw error
        }
        let streamOutcome = callCapturingErrno {
            Darwin.fstat(streamDescriptor, &streamMetadata)
        }
        guard streamOutcome.result == 0 else {
            let error = posixError(streamOutcome.errorCode)
            Darwin.close(streamDescriptor)
            throw error
        }
        guard identity(from: sourceMetadata) == identity(from: streamMetadata) else {
            Darwin.close(streamDescriptor)
            throw FlashFileBrowserFileSystemError.itemIsNotCurrent
        }
        let directoryOutcome = callCapturingErrno {
            Darwin.fdopendir(streamDescriptor)
        }
        guard let stream = directoryOutcome.result else {
            let error = posixError(directoryOutcome.errorCode)
            Darwin.close(streamDescriptor)
            throw error
        }
        defer { Darwin.closedir(stream) }

        while true {
            errno = 0
            let readOutcome = callCapturingErrno { Darwin.readdir(stream) }
            guard let entry = readOutcome.result else {
                if readOutcome.errorCode != 0 {
                    throw posixError(readOutcome.errorCode)
                }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name, !name.isEmpty else {
                throw FlashFileBrowserFileSystemError.cannotPrepareCopy
            }
            guard name != ".", name != ".." else { continue }
            try body(name)
        }
    }

    static func currentPOSIXError() -> POSIXError {
        posixError(errno)
    }

    static func posixError(_ errorCode: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
    }

    @inline(__always)
    static func callCapturingErrno<Result>(
        _ operation: () -> Result
    ) -> (result: Result, errorCode: Int32) {
        let result = operation()
        let errorCode = errno
        return (result, errorCode)
    }

    static func canonicalPath(for descriptor: Int32) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = pathBuffer.withUnsafeMutableBufferPointer {
            Darwin.fcntl(descriptor, F_GETPATH, $0.baseAddress!)
        }
        guard result == 0 else { return nil }

        return FlashFileBrowserPathPolicy.standardized(
            URL(fileURLWithPath: String(cString: pathBuffer), isDirectory: true)
        ).path
    }

    static func containsCanonicalPath(
        _ candidatePath: String,
        in rootPath: String
    ) -> Bool {
        FlashFileBrowserPathPolicy.contains(
            URL(fileURLWithPath: candidatePath, isDirectory: true),
            in: URL(fileURLWithPath: rootPath, isDirectory: true)
        )
    }

    static func identity(from metadata: stat) -> FlashFileBrowserItemIdentity {
        FlashFileBrowserItemIdentity(
            device: UInt64(truncatingIfNeeded: metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            generation: metadata.st_gen,
            birthtimeSeconds: Int64(metadata.st_birthtimespec.tv_sec),
            birthtimeNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec)
        )
    }
}
