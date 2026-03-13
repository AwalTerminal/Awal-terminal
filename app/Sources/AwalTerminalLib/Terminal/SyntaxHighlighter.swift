/// Lightweight syntax highlighter for code blocks detected by the AI analyzer.
/// Tokenizes a single line of code and returns colored spans.
/// Only overrides cells with default fg color (229,229,229) — preserves existing ANSI coloring.

// MARK: - Token Types & Colors

enum SyntaxTokenType {
    case keyword
    case builtinType
    case string
    case comment
    case number
    case operator_
    case punctuation
    case function_
    case decorator
    case constant
    case variable
    case plain
}

struct SyntaxColor {
    let r: UInt8, g: UInt8, b: UInt8
}

/// One Dark-inspired color scheme optimized for dark backgrounds.
enum SyntaxColorScheme {
    static let keyword    = SyntaxColor(r: 198, g: 120, b: 221) // purple
    static let builtinType = SyntaxColor(r: 86, g: 182, b: 194) // teal
    static let string     = SyntaxColor(r: 152, g: 195, b: 121) // green
    static let comment    = SyntaxColor(r: 92, g: 99, b: 112)   // dim gray
    static let number     = SyntaxColor(r: 209, g: 154, b: 102) // orange
    static let function_  = SyntaxColor(r: 97, g: 175, b: 239)  // blue
    static let decorator  = SyntaxColor(r: 229, g: 192, b: 123) // yellow
    static let constant   = SyntaxColor(r: 224, g: 108, b: 117) // red/pink
    static let variable   = SyntaxColor(r: 224, g: 108, b: 117) // red/pink
    static let operator_  = SyntaxColor(r: 171, g: 178, b: 191) // light gray
    static let punctuation = SyntaxColor(r: 171, g: 178, b: 191) // light gray
    static let codeBlockBg = (r: UInt8(40), g: UInt8(42), b: UInt8(46), a: UInt8(180))

    static func color(for token: SyntaxTokenType) -> SyntaxColor? {
        switch token {
        case .keyword:     return keyword
        case .builtinType: return builtinType
        case .string:      return string
        case .comment:     return comment
        case .number:      return number
        case .operator_:   return operator_
        case .punctuation: return punctuation
        case .function_:   return function_
        case .decorator:   return decorator
        case .constant:    return constant
        case .variable:    return variable
        case .plain:       return nil
        }
    }
}

// MARK: - Token Span

struct SyntaxSpan {
    let start: Int  // column index
    let length: Int
    let type: SyntaxTokenType
}

// MARK: - Language Tables

struct LanguageInfo {
    let keywords: Set<String>
    let builtinTypes: Set<String>
    let constants: Set<String>
    let commentPrefix: String
    let blockCommentStart: String?
    let blockCommentEnd: String?
}

private let pythonInfo = LanguageInfo(
    keywords: ["def", "class", "if", "elif", "else", "for", "while", "return", "import",
               "from", "as", "try", "except", "finally", "raise", "with", "yield",
               "lambda", "pass", "break", "continue", "and", "or", "not", "in", "is",
               "async", "await", "assert", "del", "global", "nonlocal"],
    builtinTypes: ["int", "float", "str", "bool", "list", "dict", "set", "tuple",
                   "bytes", "type", "object", "range", "map", "filter", "zip",
                   "enumerate", "print", "len", "None", "self", "cls"],
    constants: ["True", "False", "None", "__name__", "__main__"],
    commentPrefix: "#", blockCommentStart: nil, blockCommentEnd: nil
)

private let rustInfo = LanguageInfo(
    keywords: ["fn", "let", "mut", "const", "static", "struct", "enum", "impl", "trait",
               "pub", "mod", "use", "crate", "super", "self", "Self", "if", "else",
               "match", "for", "while", "loop", "break", "continue", "return", "as",
               "where", "async", "await", "move", "ref", "type", "unsafe", "extern",
               "dyn", "macro_rules"],
    builtinTypes: ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32",
                   "u64", "u128", "usize", "f32", "f64", "bool", "char", "str",
                   "String", "Vec", "Option", "Result", "Box", "Rc", "Arc",
                   "HashMap", "HashSet", "BTreeMap"],
    constants: ["true", "false", "None", "Some", "Ok", "Err"],
    commentPrefix: "//", blockCommentStart: "/*", blockCommentEnd: "*/"
)

private let swiftInfo = LanguageInfo(
    keywords: ["func", "let", "var", "class", "struct", "enum", "protocol", "extension",
               "if", "else", "guard", "switch", "case", "default", "for", "while",
               "repeat", "return", "throw", "throws", "try", "catch", "import",
               "public", "private", "internal", "fileprivate", "open", "static",
               "override", "init", "deinit", "self", "Self", "super", "where",
               "async", "await", "actor", "typealias", "associatedtype", "weak",
               "unowned", "lazy", "mutating", "inout", "some", "any"],
    builtinTypes: ["Int", "UInt", "Float", "Double", "Bool", "String", "Character",
                   "Array", "Dictionary", "Set", "Optional", "Result", "Void",
                   "UInt8", "UInt16", "UInt32", "UInt64", "Int8", "Int16", "Int32", "Int64"],
    constants: ["true", "false", "nil"],
    commentPrefix: "//", blockCommentStart: "/*", blockCommentEnd: "*/"
)

private let jsInfo = LanguageInfo(
    keywords: ["function", "const", "let", "var", "if", "else", "for", "while", "do",
               "switch", "case", "default", "break", "continue", "return", "throw",
               "try", "catch", "finally", "new", "delete", "typeof", "instanceof",
               "in", "of", "class", "extends", "super", "this", "import", "export",
               "from", "async", "await", "yield", "static", "get", "set"],
    builtinTypes: ["Array", "Object", "String", "Number", "Boolean", "Map", "Set",
                   "Promise", "Date", "RegExp", "Error", "Symbol", "BigInt",
                   "console", "JSON", "Math", "document", "window"],
    constants: ["true", "false", "null", "undefined", "NaN", "Infinity"],
    commentPrefix: "//", blockCommentStart: "/*", blockCommentEnd: "*/"
)

private let tsInfo = LanguageInfo(
    keywords: jsInfo.keywords.union(["type", "interface", "enum", "namespace", "declare",
                                      "abstract", "implements", "readonly", "as", "is",
                                      "keyof", "infer", "never", "unknown"]),
    builtinTypes: jsInfo.builtinTypes.union(["any", "void", "never", "unknown", "string",
                                              "number", "boolean", "symbol", "bigint",
                                              "Record", "Partial", "Required", "Readonly",
                                              "Pick", "Omit"]),
    constants: jsInfo.constants,
    commentPrefix: "//", blockCommentStart: "/*", blockCommentEnd: "*/"
)

private let goInfo = LanguageInfo(
    keywords: ["func", "var", "const", "type", "struct", "interface", "if", "else",
               "for", "range", "switch", "case", "default", "break", "continue",
               "return", "go", "defer", "select", "chan", "map", "package", "import",
               "fallthrough", "goto"],
    builtinTypes: ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16",
                   "uint32", "uint64", "float32", "float64", "complex64", "complex128",
                   "bool", "byte", "rune", "string", "error", "any"],
    constants: ["true", "false", "nil", "iota"],
    commentPrefix: "//", blockCommentStart: "/*", blockCommentEnd: "*/"
)

private let cInfo = LanguageInfo(
    keywords: ["if", "else", "for", "while", "do", "switch", "case", "default",
               "break", "continue", "return", "goto", "typedef", "struct", "union",
               "enum", "const", "static", "extern", "volatile", "register", "sizeof",
               "inline", "restrict", "auto", "signed", "unsigned"],
    builtinTypes: ["int", "char", "float", "double", "void", "long", "short",
                   "size_t", "ssize_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
                   "int8_t", "int16_t", "int32_t", "int64_t", "bool", "FILE",
                   "NULL", "ptrdiff_t"],
    constants: ["true", "false", "NULL", "EOF", "stdin", "stdout", "stderr"],
    commentPrefix: "//", blockCommentStart: "/*", blockCommentEnd: "*/"
)

private let cppInfo = LanguageInfo(
    keywords: cInfo.keywords.union(["class", "public", "private", "protected", "virtual",
                                     "override", "final", "template", "typename", "namespace",
                                     "using", "new", "delete", "try", "catch", "throw",
                                     "noexcept", "constexpr", "decltype", "nullptr",
                                     "static_cast", "dynamic_cast", "reinterpret_cast",
                                     "const_cast", "auto", "this", "friend", "operator"]),
    builtinTypes: cInfo.builtinTypes.union(["string", "vector", "map", "set", "unordered_map",
                                             "unordered_set", "shared_ptr", "unique_ptr",
                                             "optional", "variant", "tuple", "array",
                                             "std", "cout", "cin", "endl"]),
    constants: cInfo.constants.union(["nullptr"]),
    commentPrefix: "//", blockCommentStart: "/*", blockCommentEnd: "*/"
)

private let javaInfo = LanguageInfo(
    keywords: ["class", "interface", "enum", "extends", "implements", "if", "else",
               "for", "while", "do", "switch", "case", "default", "break", "continue",
               "return", "throw", "throws", "try", "catch", "finally", "new",
               "instanceof", "import", "package", "public", "private", "protected",
               "static", "final", "abstract", "synchronized", "volatile", "transient",
               "native", "super", "this", "void", "assert"],
    builtinTypes: ["int", "long", "short", "byte", "float", "double", "char", "boolean",
                   "String", "Integer", "Long", "Double", "Float", "Boolean", "Object",
                   "List", "Map", "Set", "ArrayList", "HashMap", "HashSet",
                   "Optional", "Stream", "System"],
    constants: ["true", "false", "null"],
    commentPrefix: "//", blockCommentStart: "/*", blockCommentEnd: "*/"
)

private let shellInfo = LanguageInfo(
    keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done",
               "case", "esac", "in", "function", "return", "local", "export",
               "readonly", "declare", "typeset", "source", "shift", "exit",
               "break", "continue", "select", "until", "set", "unset"],
    builtinTypes: ["echo", "printf", "read", "cd", "ls", "mkdir", "rm", "cp", "mv",
                   "cat", "grep", "sed", "awk", "find", "xargs", "sort", "uniq",
                   "wc", "head", "tail", "chmod", "chown", "curl", "wget", "tar",
                   "git", "docker", "npm", "pip", "cargo"],
    constants: ["true", "false"],
    commentPrefix: "#", blockCommentStart: nil, blockCommentEnd: nil
)

private let rubyInfo = LanguageInfo(
    keywords: ["def", "class", "module", "if", "elsif", "else", "unless", "case", "when",
               "for", "while", "until", "do", "end", "begin", "rescue", "ensure",
               "raise", "return", "yield", "block_given?", "require", "include",
               "extend", "attr_reader", "attr_writer", "attr_accessor", "self",
               "super", "then", "and", "or", "not", "in", "next", "break", "redo",
               "retry", "lambda", "proc"],
    builtinTypes: ["String", "Integer", "Float", "Array", "Hash", "Symbol", "Proc",
                   "IO", "File", "Dir", "Regexp", "Range", "Nil", "True", "False",
                   "puts", "print", "p", "gets"],
    constants: ["true", "false", "nil", "ARGV", "STDIN", "STDOUT", "STDERR"],
    commentPrefix: "#", blockCommentStart: nil, blockCommentEnd: nil
)

/// Generic fallback — strings, comments, numbers only.
private let genericInfo = LanguageInfo(
    keywords: [], builtinTypes: [], constants: [],
    commentPrefix: "#", blockCommentStart: "/*", blockCommentEnd: "*/"
)

private let languageTable: [String: LanguageInfo] = [
    "python": pythonInfo, "py": pythonInfo,
    "rust": rustInfo, "rs": rustInfo,
    "swift": swiftInfo,
    "javascript": jsInfo, "js": jsInfo, "jsx": jsInfo,
    "typescript": tsInfo, "ts": tsInfo, "tsx": tsInfo,
    "go": goInfo, "golang": goInfo,
    "c": cInfo, "h": cInfo,
    "cpp": cppInfo, "c++": cppInfo, "cxx": cppInfo, "cc": cppInfo, "hpp": cppInfo,
    "java": javaInfo,
    "sh": shellInfo, "bash": shellInfo, "zsh": shellInfo, "shell": shellInfo,
    "ruby": rubyInfo, "rb": rubyInfo,
]

// MARK: - Highlighter

final class SyntaxHighlighter {

    /// Detect language from the code fence label (e.g., "python", "```rust").
    func languageInfo(for label: String) -> LanguageInfo {
        let lower = label.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "`", with: "")
        return languageTable[lower] ?? genericInfo
    }

    /// Tokenize a single line of code, returning colored spans.
    func tokenize(line: String, language lang: LanguageInfo) -> [SyntaxSpan] {
        let chars = Array(line.unicodeScalars)
        let count = chars.count
        var spans: [SyntaxSpan] = []
        var i = 0

        while i < count {
            let ch = chars[i]

            // Line comment
            if checkLineComment(chars: chars, at: i, lang: lang) != nil {
                spans.append(SyntaxSpan(start: i, length: count - i, type: .comment))
                break // rest of line
            }

            // Block comment start
            if let bcs = lang.blockCommentStart, checkPrefix(chars: chars, at: i, prefix: bcs) {
                let start = i
                i += bcs.count
                if let bce = lang.blockCommentEnd {
                    while i < count && !checkPrefix(chars: chars, at: i, prefix: bce) {
                        i += 1
                    }
                    if i < count { i += bce.count }
                } else {
                    i = count
                }
                spans.append(SyntaxSpan(start: start, length: i - start, type: .comment))
                continue
            }

            // String literal
            if ch == UnicodeScalar("\"") || ch == UnicodeScalar("'") || ch == UnicodeScalar("`") {
                let start = i
                let quote = ch
                i += 1
                while i < count {
                    if chars[i] == UnicodeScalar("\\") {
                        i += 2 // skip escape
                    } else if chars[i] == quote {
                        i += 1
                        break
                    } else {
                        i += 1
                    }
                }
                spans.append(SyntaxSpan(start: start, length: i - start, type: .string))
                continue
            }

            // Decorator (@... or #[...)
            if ch == UnicodeScalar("@") {
                let start = i
                i += 1
                while i < count && isIdentChar(chars[i]) { i += 1 }
                if i > start + 1 {
                    spans.append(SyntaxSpan(start: start, length: i - start, type: .decorator))
                }
                continue
            }
            if ch == UnicodeScalar("#") && i + 1 < count && chars[i + 1] == UnicodeScalar("[") {
                // Rust attribute #[...]
                let start = i
                i += 2
                var depth = 1
                while i < count && depth > 0 {
                    if chars[i] == UnicodeScalar("[") { depth += 1 }
                    else if chars[i] == UnicodeScalar("]") { depth -= 1 }
                    i += 1
                }
                spans.append(SyntaxSpan(start: start, length: i - start, type: .decorator))
                continue
            }

            // Number
            if isDigit(ch) && (i == 0 || !isIdentChar(chars[i - 1])) {
                let start = i
                i += 1
                // hex: 0x...
                if ch == UnicodeScalar("0") && i < count &&
                   (chars[i] == UnicodeScalar("x") || chars[i] == UnicodeScalar("X") ||
                    chars[i] == UnicodeScalar("b") || chars[i] == UnicodeScalar("B") ||
                    chars[i] == UnicodeScalar("o") || chars[i] == UnicodeScalar("O")) {
                    i += 1
                }
                while i < count && (isHexDigit(chars[i]) || chars[i] == UnicodeScalar("_") ||
                                    chars[i] == UnicodeScalar(".") || chars[i] == UnicodeScalar("e") ||
                                    chars[i] == UnicodeScalar("E")) {
                    i += 1
                }
                // Trailing type suffixes (u32, f64, etc.)
                if i < count && (chars[i] == UnicodeScalar("u") || chars[i] == UnicodeScalar("i") ||
                                 chars[i] == UnicodeScalar("f")) {
                    i += 1
                    while i < count && isDigit(chars[i]) { i += 1 }
                }
                spans.append(SyntaxSpan(start: start, length: i - start, type: .number))
                continue
            }

            // Identifier / keyword
            if isIdentStart(ch) {
                let start = i
                i += 1
                while i < count && isIdentChar(chars[i]) { i += 1 }
                // Also allow ? and ! at end for Ruby
                if i < count && (chars[i] == UnicodeScalar("?") || chars[i] == UnicodeScalar("!")) {
                    i += 1
                }
                let word = String(line.unicodeScalars[line.unicodeScalars.index(line.unicodeScalars.startIndex, offsetBy: start)..<line.unicodeScalars.index(line.unicodeScalars.startIndex, offsetBy: i)])

                // Check if followed by ( → function call
                var nextNonSpace = i
                while nextNonSpace < count && chars[nextNonSpace] == UnicodeScalar(" ") { nextNonSpace += 1 }
                let isCall = nextNonSpace < count && chars[nextNonSpace] == UnicodeScalar("(")

                let tokenType: SyntaxTokenType
                if lang.keywords.contains(word) {
                    tokenType = .keyword
                } else if lang.builtinTypes.contains(word) {
                    tokenType = .builtinType
                } else if lang.constants.contains(word) {
                    tokenType = .constant
                } else if isCall {
                    tokenType = .function_
                } else {
                    tokenType = .plain
                }
                if tokenType != .plain {
                    spans.append(SyntaxSpan(start: start, length: i - start, type: tokenType))
                }
                continue
            }

            // Operators
            if isOperatorChar(ch) {
                let start = i
                i += 1
                // Multi-char operators: ==, !=, <=, >=, ->, =>, ::, <<, >>
                if i < count && isOperatorChar(chars[i]) { i += 1 }
                spans.append(SyntaxSpan(start: start, length: i - start, type: .operator_))
                continue
            }

            // Punctuation
            if isPunctuationChar(ch) {
                spans.append(SyntaxSpan(start: i, length: 1, type: .punctuation))
                i += 1
                continue
            }

            // Skip whitespace and anything else
            i += 1
        }

        return spans
    }

    // MARK: - Helpers

    private func checkLineComment(chars: [UnicodeScalar], at i: Int, lang: LanguageInfo) -> Bool? {
        let prefix = lang.commentPrefix
        guard !prefix.isEmpty else { return nil }
        if checkPrefix(chars: chars, at: i, prefix: prefix) {
            // For "#", make sure it's not a decorator (#[)
            if prefix == "#" && i + 1 < chars.count && chars[i + 1] == UnicodeScalar("[") {
                return nil
            }
            return true
        }
        return nil
    }

    private func checkPrefix(chars: [UnicodeScalar], at i: Int, prefix: String) -> Bool {
        let prefixScalars = Array(prefix.unicodeScalars)
        guard i + prefixScalars.count <= chars.count else { return false }
        for (j, s) in prefixScalars.enumerated() {
            if chars[i + j] != s { return false }
        }
        return true
    }

    private func isDigit(_ c: UnicodeScalar) -> Bool {
        c.value >= 0x30 && c.value <= 0x39 // 0-9
    }

    private func isHexDigit(_ c: UnicodeScalar) -> Bool {
        isDigit(c) || (c.value >= 0x41 && c.value <= 0x46) || (c.value >= 0x61 && c.value <= 0x66)
    }

    private func isIdentStart(_ c: UnicodeScalar) -> Bool {
        (c.value >= 0x41 && c.value <= 0x5A) || // A-Z
        (c.value >= 0x61 && c.value <= 0x7A) || // a-z
        c == UnicodeScalar("_")
    }

    private func isIdentChar(_ c: UnicodeScalar) -> Bool {
        isIdentStart(c) || isDigit(c)
    }

    private func isOperatorChar(_ c: UnicodeScalar) -> Bool {
        switch c {
        case UnicodeScalar("="), UnicodeScalar("+"), UnicodeScalar("-"), UnicodeScalar("*"),
             UnicodeScalar("/"), UnicodeScalar("%"), UnicodeScalar("<"), UnicodeScalar(">"),
             UnicodeScalar("!"), UnicodeScalar("&"), UnicodeScalar("|"), UnicodeScalar("^"),
             UnicodeScalar("~"), UnicodeScalar(":"):
            return true
        default:
            return false
        }
    }

    private func isPunctuationChar(_ c: UnicodeScalar) -> Bool {
        switch c {
        case UnicodeScalar("("), UnicodeScalar(")"), UnicodeScalar("["), UnicodeScalar("]"),
             UnicodeScalar("{"), UnicodeScalar("}"), UnicodeScalar(","), UnicodeScalar(";"),
             UnicodeScalar("."):
            return true
        default:
            return false
        }
    }
}
