import Foundation
import UserNotifications

struct LocalTodoCandidate: Sendable {
    let title: String
    let dueDate: Date?
    let sourceExcerpt: String
}

enum LocalTodoExtractor {
    private static let actionMarkers = [
        "提醒我", "记得", "别忘了", "别忘记", "待办", "必须",
        "我需要", "需要做", "需要设计", "需要整理", "需要添加",
        "需要加入", "要去", "要把", "得去", "计划"
    ]

    static func extract(
        from transcript: String,
        sourceClipID: UUID,
        referenceDate: Date
    ) -> [LocalTodoCandidate] {
        let sentences = transcript.components(
            separatedBy: CharacterSet(charactersIn: "。！？!?；;\n")
        )
        var seen = Set<String>()
        var candidates: [LocalTodoCandidate] = []

        for rawSentence in sentences {
            let sentence = rawSentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sentence.count >= 4,
                  !sentence.contains("是不是"),
                  !sentence.contains("能不能"),
                  !sentence.contains("要不要"),
                  !sentence.contains("是否") else { continue }
            guard actionMarkers.contains(where: sentence.contains) else { continue }

            let title = cleanedTitle(sentence)
            let key = title
                .replacingOccurrences(of: " ", with: "")
                .lowercased()
            guard title.count >= 2, !seen.contains(key) else { continue }
            seen.insert(key)
            candidates.append(LocalTodoCandidate(
                title: title,
                dueDate: inferredDueDate(from: sentence, referenceDate: referenceDate),
                sourceExcerpt: sentence
            ))
            if candidates.count == 3 { break }
        }
        return candidates
    }

    private static func cleanedTitle(_ source: String) -> String {
        var result = source
            .replacingOccurrences(of: "提醒我", with: "")
            .replacingOccurrences(of: "记得要", with: "")
            .replacingOccurrences(of: "记得", with: "")
            .replacingOccurrences(of: "别忘了", with: "")
            .replacingOccurrences(of: "别忘记", with: "")
            .replacingOccurrences(of: "待办", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        for prefix in ["嗯", "呃", "然后", "还有就是", "我需要", "需要做"] {
            if result.hasPrefix(prefix) {
                result.removeFirst(prefix.count)
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if result.count > 42 {
            result = String(result.prefix(42)) + "…"
        }
        return result
    }

    private static func inferredDueDate(
        from text: String,
        referenceDate: Date
    ) -> Date? {
        let calendar = Calendar.current
        let dayOffset: Int?
        if text.contains("后天") {
            dayOffset = 2
        } else if text.contains("明天") {
            dayOffset = 1
        } else if text.contains("今天") {
            dayOffset = 0
        } else {
            dayOffset = nil
        }

        guard let dayOffset,
              let targetDay = calendar.date(
                byAdding: .day,
                value: dayOffset,
                to: calendar.startOfDay(for: referenceDate)
              ) else { return nil }

        let expression = try? NSRegularExpression(
            pattern: "(上午|中午|下午|晚上)?\\s*([0-9一二三四五六七八九十]{1,3})\\s*[点时](半|[0-9]{1,2}分)?"
        )
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression?.firstMatch(in: text, range: range),
              let hourRange = Range(match.range(at: 2), in: text) else {
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: targetDay)
        }

        var hour = chineseNumber(String(text[hourRange])) ?? 9
        if let periodRange = Range(match.range(at: 1), in: text) {
            let period = String(text[periodRange])
            if (period == "下午" || period == "晚上") && hour < 12 {
                hour += 12
            } else if period == "中午" && hour < 11 {
                hour += 12
            }
        }
        var minute = 0
        if let minuteRange = Range(match.range(at: 3), in: text) {
            let minuteText = String(text[minuteRange])
            minute = minuteText == "半"
                ? 30
                : Int(minuteText.replacingOccurrences(of: "分", with: "")) ?? 0
        }
        return calendar.date(
            bySettingHour: min(23, hour),
            minute: min(59, minute),
            second: 0,
            of: targetDay
        )
    }

    private static func chineseNumber(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits = [
            "零": 0, "一": 1, "二": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        if text == "十" { return 10 }
        if text.hasPrefix("十"), let last = text.last.flatMap({ digits[String($0)] }) {
            return 10 + last
        }
        if text.contains("十") {
            let parts = text.split(separator: "十", omittingEmptySubsequences: false)
            let tens = parts.first.flatMap { digits[String($0)] } ?? 1
            let ones = parts.count > 1 ? (digits[String(parts[1])] ?? 0) : 0
            return tens * 10 + ones
        }
        return digits[text]
    }
}

extension Notification.Name {
    static let todoSuggestionsCreated = Notification.Name("AudioLifeTodoSuggestionsCreated")
}

@MainActor
enum TodoNotificationScheduler {
    static func schedule(for item: TodoItem) async {
        guard let dueDate = item.dueDate, dueDate > Date() else {
            cancel(for: item)
            return
        }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(
            options: [.alert, .sound, .badge]
        )) ?? false
        guard granted else { return }

        if let oldIdentifier = item.notificationIdentifier {
            center.removePendingNotificationRequests(withIdentifiers: [oldIdentifier])
        }
        let identifier = "todo-\(item.id.uuidString)"
        let content = UNMutableNotificationContent()
        content.title = "待办提醒"
        content.body = item.title
        content.sound = .default
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: dueDate
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(
                dateMatching: components,
                repeats: false
            )
        )
        do {
            try await center.add(request)
            item.notificationIdentifier = identifier
        } catch {
            DiagnosticLogger.log("todo notification scheduling failed: \(error.localizedDescription)")
        }
    }

    static func cancel(for item: TodoItem) {
        guard let identifier = item.notificationIdentifier else { return }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
        item.notificationIdentifier = nil
    }
}
