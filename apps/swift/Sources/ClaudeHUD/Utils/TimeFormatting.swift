import Foundation

func relativeTime(from dateString: String?) -> String {
    guard let dateString else { return "—" }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    var date = formatter.date(from: dateString)

    if date == nil {
        formatter.formatOptions = [.withInternetDateTime]
        date = formatter.date(from: dateString)
    }

    guard let parsedDate = date else { return "—" }

    let seconds = Date().timeIntervalSince(parsedDate)

    switch seconds {
    case ..<60:
        return "now"
    case ..<3600:
        return "\(Int(seconds / 60))m"
    case ..<86400:
        return "\(Int(seconds / 3600))h"
    case ..<604800:
        return "\(Int(seconds / 86400))d"
    case ..<2592000:
        return "\(Int(seconds / 604800))w"
    default:
        return "\(Int(seconds / 2592000))mo"
    }
}
