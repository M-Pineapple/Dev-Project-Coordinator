import Foundation

/// Normalised name matching so a wrong guess can be merged instead of duplicated.
public enum NameMatcher {
    public static func normalize(_ name: String) -> String {
        let lowered = name.lowercased()
        let scalars = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    public static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let left = normalize(a)
        let right = normalize(b)
        if left.isEmpty || right.isEmpty { return false }
        if left == right { return true }
        if left.count >= 4 && right.count >= 4 {
            if left.contains(right) || right.contains(left) { return true }
        }
        if left.count <= 24 && right.count <= 24 {
            return levenshtein(left, right) <= 2
        }
        return false
    }

    public static func closest(to query: String, in names: [String]) -> String? {
        let needle = normalize(query)
        guard !needle.isEmpty else { return nil }
        if let exact = names.first(where: { normalize($0) == needle }) {
            return exact
        }
        return names.first(where: { isNearDuplicate($0, query) })
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(
                    prev[j] + 1,
                    current[j - 1] + 1,
                    prev[j - 1] + cost
                )
            }
            prev = current
        }
        return prev[bChars.count]
    }
}
