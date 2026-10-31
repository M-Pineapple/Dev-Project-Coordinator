import Foundation

/// HTML-escape user strings before interpolating into the desk page.
public enum HTMLEscape {
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 38: out.append("&amp;")
            case 60: out.append("&lt;")
            case 62: out.append("&gt;")
            case 34: out.append("&quot;")
            case 39: out.append("&#39;")
            default: out.append(Character(scalar))
            }
        }
        return out
    }
}
