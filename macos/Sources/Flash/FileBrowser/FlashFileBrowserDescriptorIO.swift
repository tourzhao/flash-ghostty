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
        let streamDescriptor = Darwin.fcntl(
            descriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard streamDescriptor >= 0 else { throw currentPOSIXError() }
        guard let stream = Darwin.fdopendir(streamDescriptor) else {
            Darwin.close(streamDescriptor)
            throw currentPOSIXError()
        }
        defer { Darwin.closedir(stream) }

        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                if errno != 0 { throw currentPOSIXError() }
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
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
