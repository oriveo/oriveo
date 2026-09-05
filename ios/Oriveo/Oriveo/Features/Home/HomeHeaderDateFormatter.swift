import Foundation

func isHomeHeaderCJKLocale(_ locale: Locale) -> Bool {
    guard let languageCode = locale.language.languageCode?.identifier else {
        return false
    }
    return ["zh", "ja", "ko"].contains(languageCode)
}

func formatHomeHeaderDate(
    _ date: Date,
    locale: Locale,
    timeZone: TimeZone = .current
) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone

    switch locale.language.languageCode?.identifier {
    case "zh", "ja":
        // Month and day markers as written in Chinese and Japanese dates.
        formatter.dateFormat = "M月d日 EEEE"
    case "ko":
        formatter.dateFormat = "M월 d일 EEEE"
    default:
        formatter.dateFormat = "EEEE, MMMM d"
    }

    return formatter.string(from: date)
}
