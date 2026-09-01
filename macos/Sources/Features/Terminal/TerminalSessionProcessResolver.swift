import Darwin
import Foundation

/// Synchronous process-tree lookup with no AppKit dependencies. Callers run it
/// on a utility queue and publish the result back on the main queue.
enum TerminalSessionProcessResolver {
    static func foregroundProcessName(
        startingAt initialProcessID: Int32,
        applicationProcessID: Int32 = getpid()
    ) -> String? {
        var processID = initialProcessID
        var nearestProcessName: String?

        for _ in 0..<12 {
            guard processID > 1, processID != applicationProcessID else { break }

            var buffer = [CChar](repeating: 0, count: 1024)
            let length = proc_name(processID, &buffer, UInt32(buffer.count))
            if length > 0 {
                let name = String(cString: buffer)
                if nearestProcessName == nil {
                    nearestProcessName = name
                }

                let tool = TerminalSessionTool.detect(
                    fromDynamicTitle: "",
                    foregroundProcessName: name
                )
                if tool != .terminal {
                    return canonicalProcessName(for: tool)
                }
            }

            if let executablePath = processExecutablePath(processID) {
                let tool = TerminalSessionTool.detect(
                    fromDynamicTitle: "",
                    foregroundProcessName: executablePath
                )
                if tool != .terminal {
                    return canonicalProcessName(for: tool)
                }
            }

            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                &info,
                infoSize
            ) == infoSize else { break }

            let parent = Int32(bitPattern: info.pbi_ppid)
            guard parent != processID else { break }
            processID = parent
        }

        return nearestProcessName
    }

    private static func processExecutablePath(_ processID: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else {
            return nil
        }

        return String(cString: buffer)
    }

    private static func canonicalProcessName(for tool: TerminalSessionTool) -> String {
        switch tool {
        case .codex: "codex"
        case .claudeCode: "claude"
        case .terminal: ""
        }
    }
}
