import Darwin
import Foundation
import GhosttyKit

enum TerminalSessionTool: Equatable, Sendable {
    case codex
    case claudeCode
    case terminal

    static func detect(
        fromDynamicTitle title: String,
        foregroundProcessName: String? = nil
    ) -> Self {
        TerminalSessionMetadataProviders.tool(
            dynamicTitle: title,
            foregroundProcessName: foregroundProcessName
        )
    }
}

/// The user-facing activity state for a sidebar session.
///
/// `ready` is intentionally distinct from `completed`: an agent starts ready,
/// and only becomes completed after an observed active or paused turn ends.
enum TerminalSessionActivityStatus: Equatable, Sendable {
    case ready
    case active
    case paused
    case completed
    case failed
}

/// Provider-specific terminal conventions are isolated behind this protocol so
/// adding another agent does not add branches to the sidebar or window controller.
private protocol TerminalSessionMetadataProvider {
    var tool: TerminalSessionTool { get }

    func matches(dynamicTitle: String, foregroundProcessName: String?) -> Bool

    func status(
        dynamicTitle: String,
        visibleContents: String,
        previous: TerminalSessionActivityStatus
    ) -> TerminalSessionActivityStatus

    func lastInstruction(visibleContents: String) -> String?
}

private struct CodexSessionMetadataProvider: TerminalSessionMetadataProvider {
    let tool = TerminalSessionTool.codex

    private static let spinnerFrames = Set("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
    private static let activeTitles: Set<String> = [
        "starting",
        "working",
        "waiting",
        "thinking",
    ]

    func matches(dynamicTitle: String, foregroundProcessName: String?) -> Bool {
        if let foregroundTool = TerminalSessionMetadataProviders
            .foregroundTool(foregroundProcessName) {
            return foregroundTool == tool
        }
        guard TerminalSessionMetadataProviders
            .allowsTitleFallback(foregroundProcessName) else { return false }

        let title = TerminalSessionMetadataProviders.normalizedTitle(dynamicTitle)
        return title == "codex" || title.hasPrefix("codex ")
    }

    func status(
        dynamicTitle: String,
        visibleContents: String,
        previous: TerminalSessionActivityStatus
    ) -> TerminalSessionActivityStatus {
        let title = dynamicTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title.lowercased()

        if normalizedTitle.hasPrefix("[ ! ] action required") ||
            normalizedTitle.hasPrefix("[ . ] action required") {
            return .paused
        }

        if title.first.map(Self.spinnerFrames.contains) == true ||
            Self.activeTitles.contains(normalizedTitle) {
            return .active
        }

        return TerminalSessionMetadataProviders.idleStatus(after: previous)
    }

    func lastInstruction(visibleContents: String) -> String? {
        TerminalSessionInstructionParser.lastInstruction(
            prefix: "›",
            visibleContents: visibleContents
        )
    }
}

private struct ClaudeCodeSessionMetadataProvider: TerminalSessionMetadataProvider {
    let tool = TerminalSessionTool.claudeCode

    private static let spinnerFrames = Set("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

    func matches(dynamicTitle: String, foregroundProcessName: String?) -> Bool {
        if let foregroundTool = TerminalSessionMetadataProviders
            .foregroundTool(foregroundProcessName) {
            return foregroundTool == tool
        }
        guard TerminalSessionMetadataProviders
            .allowsTitleFallback(foregroundProcessName) else { return false }

        let titleWords = TerminalSessionMetadataProviders.words(in: dynamicTitle)
        let title = TerminalSessionMetadataProviders.normalizedTitle(dynamicTitle)
        return title == "claude" || title == "claude-code" ||
            titleWords.elementsEqual(["claude", "code"]) ||
            (titleWords.suffix(2).elementsEqual(["claude", "code"]) &&
                titleWords.count <= 3)
    }

    func status(
        dynamicTitle: String,
        visibleContents: String,
        previous: TerminalSessionActivityStatus
    ) -> TerminalSessionActivityStatus {
        let title = dynamicTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // A live spinner is a current provider signal. Permission text can
        // remain in the viewport after the user answers it, so it must not
        // override evidence that Claude has resumed work.
        if title.first.map(Self.spinnerFrames.contains) == true {
            return .active
        }

        if Self.visibleTailRequiresInput(visibleContents) {
            return .paused
        }

        return TerminalSessionMetadataProviders.idleStatus(after: previous)
    }

    func lastInstruction(visibleContents: String) -> String? {
        TerminalSessionInstructionParser.lastInstruction(
            prefix: "❯",
            visibleContents: visibleContents
        )
    }

    private static func visibleTailRequiresInput(_ contents: String) -> Bool {
        let tail = contents
            .split(whereSeparator: { $0.isNewline })
            .suffix(18)
            .joined(separator: "\n")
            .lowercased()

        guard !tail.isEmpty else { return false }

        if tail.contains("claude needs your permission") ||
            tail.contains("waiting for your input") ||
            tail.contains("would you like to proceed?") ||
            tail.contains("allow for this session") ||
            tail.contains("yes, and don't ask again") ||
            tail.contains("yes, and allow") {
            return true
        }

        let hasQuestion = tail.contains("do you want to ") ||
            tail.contains("do you want to proceed?")
        let hasYesAndNo = tail.contains("yes") && tail.contains("no")
        let hasSelectionFooter = tail.contains("esc to cancel") &&
            (tail.contains("enter to select") || hasYesAndNo)
        return (hasQuestion && hasYesAndNo) || hasSelectionFooter
    }
}

private enum TerminalSessionMetadataProviders {
    private static let providers: [TerminalSessionMetadataProvider] = [
        CodexSessionMetadataProvider(),
        ClaudeCodeSessionMetadataProvider(),
    ]

    static func tool(
        dynamicTitle: String,
        foregroundProcessName: String?
    ) -> TerminalSessionTool {
        providers.first {
            $0.matches(
                dynamicTitle: dynamicTitle,
                foregroundProcessName: foregroundProcessName
            )
        }?.tool ?? .terminal
    }

    static func status(
        tool: TerminalSessionTool,
        dynamicTitle: String,
        visibleContents: String,
        previous: TerminalSessionActivityStatus
    ) -> TerminalSessionActivityStatus {
        guard let provider = providers.first(where: { $0.tool == tool }) else {
            return .ready
        }

        return provider.status(
            dynamicTitle: dynamicTitle,
            visibleContents: visibleContents,
            previous: previous
        )
    }

    static func lastInstruction(
        tool: TerminalSessionTool,
        visibleContents: String
    ) -> String? {
        providers.first(where: { $0.tool == tool })?
            .lastInstruction(visibleContents: visibleContents)
    }

    static func foregroundTool(_ value: String?) -> TerminalSessionTool? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let processWords = words(in: value)
        if processWords.contains("codex") { return .codex }
        if processWords.contains("claude") { return .claudeCode }
        return nil
    }

    /// Node-based agent CLIs often expose only their runtime as the foreground
    /// process. In that case a strict, provider-owned terminal title is the best
    /// available evidence. Ordinary shells and editors remain authoritative so
    /// a stale title cannot keep an agent icon after the agent exits.
    static func allowsTitleFallback(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return true }
        let executable = URL(fileURLWithPath: value).lastPathComponent.lowercased()
        return ["node", "nodejs", "npm", "npx", "bun", "deno"].contains(executable)
    }

    static func normalizedTitle(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func words(in value: String) -> [Substring] {
        value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
    }

    static func idleStatus(
        after previous: TerminalSessionActivityStatus
    ) -> TerminalSessionActivityStatus {
        switch previous {
        case .active, .paused:
            return .completed
        case .completed, .failed:
            return previous
        case .ready:
            return .ready
        }
    }
}

/// Derives an agent activity state from structured terminal progress first,
/// then delegates provider-specific fallbacks to the matching provider.
struct TerminalSessionActivityClassifier {
    static func retainedProgressReport(
        current: Ghostty.Action.ProgressReport?,
        incoming: Ghostty.Action.ProgressReport?
    ) -> Ghostty.Action.ProgressReport? {
        incoming ?? current
    }

    static func status(
        tool: TerminalSessionTool,
        dynamicTitle: String,
        progressReport: Ghostty.Action.ProgressReport?,
        visibleContents: String,
        previous: TerminalSessionActivityStatus
    ) -> TerminalSessionActivityStatus {
        if let progressReport {
            switch progressReport.state {
            case .set, .indeterminate:
                return .active
            case .pause:
                return .paused
            case .error:
                return .failed
            case .remove:
                return .completed
            }
        }

        return TerminalSessionMetadataProviders.status(
            tool: tool,
            dynamicTitle: dynamicTitle,
            visibleContents: visibleContents,
            previous: previous
        )
    }
}

struct TerminalSessionInstructionExtractor {
    static func lastInstruction(
        tool: TerminalSessionTool,
        visibleContents: String
    ) -> String? {
        TerminalSessionMetadataProviders.lastInstruction(
            tool: tool,
            visibleContents: visibleContents
        )
    }
}

private enum TerminalSessionInstructionParser {
    private static let maximumSummaryLength = 512

    static func lastInstruction(
        prefix: Character,
        visibleContents: String
    ) -> String? {
        let lines = visibleContents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        guard lines.count >= 3 else { return nil }

        for index in lines.indices.reversed() {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.first == prefix else { continue }

            let firstLine = line.dropFirst().trimmingCharacters(in: .whitespaces)
            guard !firstLine.isEmpty,
                  !looksLikePickerOption(firstLine, at: index, in: lines)
            else { continue }

            guard index > lines.startIndex,
                  lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }

            var parts = [String(firstLine)]
            var cursor = index + 1
            while cursor < lines.endIndex {
                let continuation = lines[cursor].trimmingCharacters(in: .whitespaces)
                if continuation.isEmpty { break }
                parts.append(continuation)
                cursor += 1
            }

            guard cursor < lines.endIndex else { continue }
            let result = normalized(parts.joined(separator: " "))
            if !result.isEmpty { return result }
        }

        return nil
    }

    private static func looksLikePickerOption(
        _ value: String,
        at index: Int,
        in lines: [String]
    ) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = text.lowercased()

        let isChoiceLike = lowercased == "yes" || lowercased == "no" ||
            lowercased == "tell claude what to do instead" ||
            lowercased.hasPrefix("type your answer") ||
            text.hasPrefix("[ ]") || text.hasPrefix("[x]") || text.hasPrefix("[X]") ||
            isNumberedChoice(text)
        guard isChoiceLike else { return false }

        let lowerBound = max(lines.startIndex, index - 4)
        let upperBound = min(lines.endIndex, index + 6)
        let nearbyLines = lines[lowerBound..<upperBound].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let context = nearbyLines.joined(separator: " ").lowercased()
        let hasPickerPrompt = context.contains("permission") ||
            context.contains("enter to select") ||
            context.contains("esc to cancel") ||
            context.contains("would you like to") ||
            context.contains("do you want to") ||
            context.contains("select an option")
        let choiceCount = nearbyLines.filter { nearbyLine in
            let nearbyLowercased = nearbyLine.lowercased()
            return nearbyLowercased == "yes" || nearbyLowercased == "no" ||
                nearbyLowercased == "tell claude what to do instead" ||
                nearbyLowercased.hasPrefix("type your answer") ||
                nearbyLine.hasPrefix("[ ]") || nearbyLine.hasPrefix("[x]") ||
                nearbyLine.hasPrefix("[X]") || isNumberedChoice(nearbyLine)
        }.count

        return hasPickerPrompt || choiceCount > 1
    }

    private static func isNumberedChoice(_ text: String) -> Bool {
        let digits = text.prefix(while: \Character.isNumber)
        guard !digits.isEmpty, digits.endIndex < text.endIndex else { return false }
        return ".):".contains(text[digits.endIndex])
    }

    private static func normalized(_ value: String) -> String {
        let result = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(result.prefix(maximumSummaryLength))
    }
}

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
