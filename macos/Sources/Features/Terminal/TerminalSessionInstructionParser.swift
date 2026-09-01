import Foundation

/// Module-internal because provider implementations live in a separate file;
/// parser helpers and constants remain private to this type.
enum TerminalSessionInstructionParser {
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
