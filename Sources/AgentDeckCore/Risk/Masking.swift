import Foundation

public enum Masking {
    // Each credential keeps a short non-secret prefix and is replaced by "••••", so masking is idempotent.
    // Only URL passwords and KEY=value assignments can be shorter than the mask (the string may grow by ≤ 3 characters).
    private static func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
    private static let rules: [(NSRegularExpression, String)] = [
        (re(#"-----BEGIN ([A-Z0-9 ]*)PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)"#),
         "-----BEGIN $1PRIVATE KEY-----••••-----END $1PRIVATE KEY-----"),
        (re(#"\beyJ[A-Za-z0-9_-]{5,}\.eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"#), "eyJ••••"),
        (re(#"(\bbearer\s+)([A-Za-z0-9._~+/=-]{4})[A-Za-z0-9._~+/=-]{12,}"#, [.caseInsensitive]), "$1$2••••"),
        (re(#"(\bsk-[A-Za-z0-9_-])[A-Za-z0-9_-]{15,}"#), "$1••••"),
        (re(#"(\bAKIA)[0-9A-Z]{16}"#), "$1••••"),
        (re(#"(\bgithub_pat_)[A-Za-z0-9_]{16,}"#), "$1••••"),
        (re(#"(\bgh[pousr]_)[A-Za-z0-9]{16,}"#), "$1••••"),
        (re(#"(\bxox[abposr]-)[A-Za-z0-9-]{10,}"#), "$1••••"),
        (re(#"(\b[A-Za-z][A-Za-z0-9+.-]*://[^\s/:@]+:)[^\s/@]+(@)"#), "$1••••$2"),
        // Env-style NAME=value only (upper-case name, no `$VAR` reference), so ordinary code like `token = x` stays readable.
        (re(#"(\b[A-Z0-9_]{0,40}(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Z0-9_]{0,40}=)(?:"[^"\n]*"|'[^'\n]*'|(?![$"'])[^\s"']+)"#), "$1••••"),
    ]

    public static func mask(_ s: String) -> String {
        var out = s
        for (re, template) in rules {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}
