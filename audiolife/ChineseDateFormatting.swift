import Foundation

extension Date {
    var chineseFullDate: String {
        ChineseDateFormatters.full.string(from: self)
    }

    var chineseMonthDayWeekday: String {
        ChineseDateFormatters.monthDayWeekday.string(from: self)
    }

    var chineseMonth: String {
        ChineseDateFormatters.month.string(from: self)
    }

    var chineseDay: String {
        ChineseDateFormatters.day.string(from: self)
    }

    var chineseTime: String {
        ChineseDateFormatters.time.string(from: self)
    }
}

private enum ChineseDateFormatters {
    static let full = make("yyyy年M月d日 EEEE")
    static let monthDayWeekday = make("M月d日 EEEE")
    static let month = make("M月")
    static let day = make("d")
    static let time = make("HH:mm")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }
}

