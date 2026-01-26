import Foundation

enum RelativeTimeFormatter {

    /// Formats a date into human-friendly relative time.
    /// - Parameter date: The date to format
    /// - Returns: Relative time string like "now", "5m ago", "2h ago", "3d ago", or "Dec 15"
    static func format(_ date: Date) -> String {
        let now = Date()
        let seconds = now.timeIntervalSince(date)

        guard seconds >= 0 else {
            return "now"
        }

        let minutes = Int(seconds / 60)
        let hours = Int(seconds / 3600)
        let days = Int(seconds / 86400)

        if seconds < 60 {
            return "now"
        } else if minutes < 60 {
            return "\(minutes)m ago"
        } else if hours < 24 {
            return "\(hours)h ago"
        } else if days < 7 {
            return "\(days)d ago"
        } else if days < 30 {
            let weeks = days / 7
            return "\(weeks)w ago"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }

    /// Formats an ISO8601 timestamp string into relative time.
    /// Handles both standard and fractional-second formats from Rust.
    /// - Parameter timestamp: ISO8601 timestamp string
    /// - Returns: Relative time string, or "never" if parsing fails
    static func format(iso8601 timestamp: String?) -> String {
        guard let timestamp = timestamp, !timestamp.isEmpty else {
            return "never"
        }

        if let date = parseISO8601(timestamp) {
            return format(date)
        }

        return "never"
    }

    /// Parses an ISO8601 timestamp, handling both standard and fractional-second formats.
    /// Rust emits timestamps with microsecond precision (e.g., "2026-01-24T22:34:54.629248Z")
    /// which requires the `.withFractionalSeconds` option.
    static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: string) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
