import Foundation

/// Human-readable dates follow the phone's region, calendar, clock and time zone.
/// Create formatters on demand so cached values cannot retain an old time zone.
nonisolated enum AppDateFormatting {
    static func string(
        from date: Date,
        template: String? = nil,
        dateStyle: DateFormatter.Style = .medium,
        timeStyle: DateFormatter.Style = .none,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        if let template {
            formatter.setLocalizedDateFormatFromTemplate(template)
        } else {
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
        }
        return formatter.string(from: date)
    }
}

extension Date {
    nonisolated var displayFullDate: String { AppDateFormatting.string(from: self, template: "yMMMMdEEEE") }
    nonisolated var displayMonthDayWeekday: String { AppDateFormatting.string(from: self, template: "MMMdEEEE") }
    nonisolated var displayMonth: String { AppDateFormatting.string(from: self, template: "MMMM") }
    nonisolated var displayDay: String { AppDateFormatting.string(from: self, template: "d") }
    nonisolated var displayTime: String { AppDateFormatting.string(from: self, dateStyle: .none, timeStyle: .short) }
    nonisolated var displayDate: String { AppDateFormatting.string(from: self) }
    nonisolated var displayDateTime: String { AppDateFormatting.string(from: self, timeStyle: .short) }
    nonisolated var displayCompactDateTime: String { AppDateFormatting.string(from: self, template: "MMMdjmm") }
    nonisolated var displayMonthDay: String { AppDateFormatting.string(from: self, template: "MMMd") }
    nonisolated var displayMonthYear: String { AppDateFormatting.string(from: self, template: "yMMMM") }
}
