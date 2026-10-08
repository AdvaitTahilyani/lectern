import Foundation

/// Turns the LaTeX that models like to emit ("FIRST($\alpha$)", "$A \to \beta A'$") into plain
/// Unicode text for cards that render plain strings.
enum PlainMath {
    private static let commands: [(String, String)] = [
        ("varepsilon", "ε"), ("epsilon", "ε"), ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ"),
        ("lambda", "λ"), ("sigma", "σ"), ("tau", "τ"), ("phi", "φ"), ("varphi", "φ"), ("omega", "ω"), ("pi", "π"),
        ("rightarrow", "→"), ("Rightarrow", "⇒"), ("leftarrow", "←"), ("to", "→"), ("mapsto", "↦"),
        ("notin", "∉"), ("in", "∈"), ("cup", "∪"), ("cap", "∩"), ("subseteq", "⊆"), ("subset", "⊂"),
        ("emptyset", "∅"), ("varnothing", "∅"), ("neq", "≠"), ("ne", "≠"), ("leq", "≤"), ("le", "≤"),
        ("geq", "≥"), ("ge", "≥"), ("times", "×"), ("cdot", "·"), ("ldots", "…"), ("dots", "…"), ("cdots", "…"),
        ("forall", "∀"), ("exists", "∃"), ("neg", "¬"), ("land", "∧"), ("lor", "∨"), ("vert", "|"), ("mid", "|"),
        ("quad", " "), ("qquad", " "), ("log", "log"),
    ]

    /// LaTeX command names, for telling "\\to" or "\\text" apart from JSON escapes like "\\t".
    static let commandNames: Set<String> = Set(commands.map(\.0)).union([
        "text", "textbf", "textit", "texttt", "mathrm", "mathit", "mathbf", "operatorname", "frac", "theta",
        "rho", "nu", "nabla", "newline", "right", "left", "not", "bar", "hat", "vec", "tilde", "rangle", "langle",
    ])

    /// - Parameter preservingLines: keep line structure (for Markdown answers) instead of collapsing
    ///   all whitespace.
    static func clean(_ text: String, preservingLines: Bool = false) -> String {
        guard text.contains("\\") || text.contains("$") else {
            return preservingLines ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
        }
        var s = text
        // Math delimiters "$…$" around LaTeX-looking content (a lone "$", the end marker in
        // "$ ∈ FOLLOW(S)", is left alone).
        s = s.replacing(/\$([^\s$][^$\n]{0,198}?[^\s$]|[^\s$])\$/) { match in
            let inner = String(match.1)
            return inner.contains("\\") || inner.contains("_") || inner.contains("^") ? inner : String(match.0)
        }
        // \text{…}, \mathrm{…}, \texttt{…} → contents, innermost first ("\mathbf{2.5 \text{ cycles}}")
        for _ in 0..<3 {
            let unwrapped = s.replacing(/\\(?:text|mathrm|mathit|mathbf|textbf|texttt|operatorname)\{([^{}]*)\}/) { String($0.1) }
            if unwrapped == s { break }
            s = unwrapped
        }
        s = s.replacing(/\\([{}$_%&#])/) { String($0.1) }
        for (name, symbol) in commands.sorted(by: { $0.0.count > $1.0.count }) {
            s = s.replacing(try! Regex("\\\\\(name)(?![A-Za-z])"), with: symbol)
        }
        // Subscripts/superscripts with braces: Y_{k} → Yk, x^{2} → x^2
        s = s.replacing(/_\{([^{}]*)\}/) { String($0.1) }
        s = s.replacing(/\^\{([^{}]*)\}/) { "^" + $0.1 }
        return preservingLines ? s.trimmingCharacters(in: .whitespacesAndNewlines) : Text.collapse(s)
    }
}
