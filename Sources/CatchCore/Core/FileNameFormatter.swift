import Foundation

public struct FileNameToken: Identifiable, Sendable {
    public let id: String
    public let token: String
    public let label: String

    public init(token: String, label: String) {
        self.id = token
        self.token = token
        self.label = label
    }
}

public enum FileNameFormatter {
    public static let availableTokens: [FileNameToken] = [
        FileNameToken(token: "%y", label: "Year"),
        FileNameToken(token: "%m", label: "Month (numeric)"),
        FileNameToken(token: "%n", label: "Month (name)"),
        FileNameToken(token: "%d", label: "Day"),
        FileNameToken(token: "%w", label: "Day of week"),
        FileNameToken(token: "%t", label: "Window title"),
        FileNameToken(token: "%a", label: "App name"),
        FileNameToken(token: "%H", label: "Hour"),
        FileNameToken(token: "%M", label: "Minutes"),
        FileNameToken(token: "%S", label: "Seconds"),
        FileNameToken(token: "%p", label: "AM/PM"),
        FileNameToken(token: "%r", label: "Random characters"),
        FileNameToken(token: "%i", label: "Auto-increment")
    ]

    public static func format(
        pattern: String = "Catch %y-%m-%d at %H.%M.%S",
        date: Date = Date(),
        windowTitle: String? = nil,
        appName: String? = nil,
        isRetina: Bool = false,
        add2xSuffix: Bool = false,
        useUTC: Bool = false,
        removeIllegalCharacters: Bool = true,
        autoIncrementCounter: Int = 1,
        randomGenerator: (() -> String)? = nil
    ) -> String {
        let tz = useUTC ? TimeZone(secondsFromGMT: 0)! : TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)

        let monthNames = DateFormatter().monthSymbols ?? ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        let weekdayNames = DateFormatter().weekdaySymbols ?? ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

        let year = String(format: "%04d", comps.year ?? 2026)
        let monthNum = String(format: "%02d", comps.month ?? 1)
        let monthIndex = max(0, min(monthNames.count - 1, (comps.month ?? 1) - 1))
        let monthName = monthNames[monthIndex]
        let day = String(format: "%02d", comps.day ?? 1)
        let weekdayIndex = max(0, min(weekdayNames.count - 1, (comps.weekday ?? 1) - 1))
        let weekdayName = weekdayNames[weekdayIndex]

        let hour24 = comps.hour ?? 0
        let uses12Hour = pattern.contains("%p")
        let displayHour = uses12Hour ? ((hour24 % 12 == 0) ? 12 : (hour24 % 12)) : hour24
        let hour = String(format: "%02d", displayHour)
        let minute = String(format: "%02d", comps.minute ?? 0)
        let second = String(format: "%02d", comps.second ?? 0)
        let ampm = hour24 >= 12 ? "PM" : "AM"

        let rand = randomGenerator?() ?? randomString(length: 4)
        let cleanWindowTitle = (windowTitle?.isEmpty == false ? windowTitle! : "Untitled")
        let cleanAppName = (appName?.isEmpty == false ? appName! : "Desktop")

        let replacements: [(String, String)] = [
            ("%y", year),
            ("%m", monthNum),
            ("%n", monthName),
            ("%d", day),
            ("%w", weekdayName),
            ("%t", cleanWindowTitle),
            ("%a", cleanAppName),
            ("%H", hour),
            ("%M", minute),
            ("%S", second),
            ("%p", ampm),
            ("%r", rand),
            ("%i", String(autoIncrementCounter))
        ]

        var result = pattern
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }

        if removeIllegalCharacters {
            let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            result = result.components(separatedBy: illegal).joined(separator: "-")
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty {
            result = "Catch"
        }

        if isRetina && add2xSuffix && !result.hasSuffix("@2x") {
            result += "@2x"
        }
        return result
    }

    private static func randomString(length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}
