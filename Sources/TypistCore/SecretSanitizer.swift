import Foundation

/// Removes things that look like secrets from text before it is stored as a
/// writing sample or handed to the model as context.
public enum SecretSanitizer {
    public static let placeholder = "[redacted]"

    private static let patterns: [NSRegularExpression] = [
        // IBAN
        #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,3})?\b"#,
        // Payment card numbers (checked with Luhn below)
        #"\b\d(?:[ -]?\d){12,18}\b"#,
        // Well-known token prefixes
        #"\b(?:sk|pk|rk)[-_](?:live|test|proj|ant)?[-_]?[A-Za-z0-9_\-]{16,}\b"#,
        #"\b(?:ghp|gho|ghu|ghs|github_pat|xox[abprs]|AKIA|AIza)[A-Za-z0-9_\-]{12,}\b"#,
        // JSON web tokens
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#,
        // Private key blocks
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"#,
        // Long random-looking strings (hex or base64-ish with digits)
        #"\b(?=[A-Za-z0-9+/_\-]*\d)(?=[A-Za-z0-9+/_\-]*[A-Za-z])[A-Za-z0-9+/_\-]{32,}={0,2}"#,
        // key=value style secrets
        #"(?i)\b(?:password|passwd|pwd|secret|api[_-]?key|token)\b\s*[:=]\s*\S+"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func sanitize(_ text: String) -> String {
        var result = text
        for (index, pattern) in patterns.enumerated() {
            let source = result as NSString
            var output = ""
            var cursor = 0
            for match in pattern.matches(in: result, range: NSRange(location: 0, length: source.length)) {
                let candidate = source.substring(with: match.range)
                // Index 1 is the card pattern: plain long numbers are only secrets if they pass Luhn.
                if index == 1, !passesLuhn(candidate) { continue }
                output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)) + placeholder
                cursor = match.range.location + match.range.length
            }
            result = output + source.substring(from: cursor)
        }
        return result
    }

    static func passesLuhn(_ text: String) -> Bool {
        let digits = text.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            let doubled = offset % 2 == 1 ? digit * 2 : digit
            sum += doubled > 9 ? doubled - 9 : doubled
        }
        return sum % 10 == 0
    }
}
