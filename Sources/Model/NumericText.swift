import Foundation

/// Shared numeric check for text values coming from the database. It accepts
/// both `.` and `,` as the decimal separator, matching the values a
/// Russian-locale grid can contain.
enum NumericText {
    static func isNumeric(_ text: String) -> Bool {
        Double(text.replacingOccurrences(of: ",", with: ".")) != nil
    }
}
