import Foundation

enum Connector { case always, and, or }

struct Word: Equatable {
    var text = ""
    /// `text` with quoted glob characters escaped, for `fnmatch`.
    var pattern = ""
    var globbed = false
    var quoted = false
}

enum Redirect: Equatable { case output, append, input, errorOutput, errorAppend, errorToOutput, bothOutput }

enum Token: Equatable {
    case word(Word)
    case pipe
    case redirect(Redirect)
}

struct ShellError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// A small POSIX-ish subset: quotes, `\`, `$VAR`, `~`, globs, `|`, `<` `>` `>>` `2>` `2>&1` `&>`, `;` `&&` `||`, `#`.
enum ShellSyntax {
    /// Splits a line into commands to run in turn, each with how it depends on the one before.
    static func split(_ line: String) throws -> [(String, Connector)] {
        let c = Array(line)
        var out: [(String, Connector)] = []
        var cur = "", next = Connector.always
        var quote: Character?
        var wordStart = true
        var i = 0

        func push(_ conn: Connector) {
            if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append((cur, next)) }
            cur = ""
            next = conn
        }

        scan: while i < c.count {
            let ch = c[i]
            if let q = quote {
                cur.append(ch)
                if ch == "\\", q == "\"", i + 1 < c.count {
                    cur.append(c[i + 1])
                    i += 1
                } else if ch == q {
                    quote = nil
                }
                i += 1
                wordStart = false
                continue
            }
            switch ch {
            case "\\":
                cur.append(ch)
                if i + 1 < c.count { cur.append(c[i + 1]); i += 1 }
            case "'", "\"":
                quote = ch
                cur.append(ch)
            case "#" where wordStart:
                break scan
            case ";":
                push(.always)
            case "&":
                if i + 1 < c.count, c[i + 1] == "&" {
                    push(.and)
                    i += 1
                } else if cur.last == ">" || (i + 1 < c.count && c[i + 1] == ">") {
                    cur.append(ch)
                } else {
                    push(.always)
                }
            case "|":
                if i + 1 < c.count, c[i + 1] == "|" {
                    push(.or)
                    i += 1
                } else {
                    cur.append(ch)
                }
            default:
                cur.append(ch)
            }
            wordStart = ch.isWhitespace || ";&|".contains(ch)
            i += 1
        }
        if quote != nil { throw ShellError("unterminated quote") }
        push(.always)
        return out
    }

    static func tokens(_ segment: String, variable: (String) -> String?, home: String) throws -> [Token] {
        let c = Array(segment)
        var tokens: [Token] = []
        var w = Word(), inWord = false
        var i = 0

        func literal(_ s: String) {
            w.text += s
            w.pattern += s.map(escape).joined()
            inWord = true
        }
        func end() {
            if inWord { tokens.append(.word(w)) }
            w = Word()
            inWord = false
        }
        /// The value of the `$…` at `i`, and where it ends.
        func expand(_ i: Int) -> (String, Int) {
            var j = i + 1
            guard j < c.count else { return ("$", j) }
            if c[j] == "{" {
                guard let close = c[j...].firstIndex(of: "}") else { return ("$", j) }
                return (variable(String(c[(j + 1)..<close])) ?? "", close + 1)
            }
            if "?$#".contains(c[j]) || c[j].isNumber { return (variable(String(c[j])) ?? "", j + 1) }
            guard c[j] == "_" || c[j].isLetter else { return ("$", j) }
            while j < c.count, c[j] == "_" || c[j].isLetter || c[j].isNumber { j += 1 }
            return (variable(String(c[(i + 1)..<j])) ?? "", j)
        }

        while i < c.count {
            let ch = c[i]
            let next: Character? = i + 1 < c.count ? c[i + 1] : nil
            switch ch {
            case _ where ch.isWhitespace:
                end()
            case "'":
                guard let close = c[(i + 1)...].firstIndex(of: "'") else { throw ShellError("unterminated quote") }
                literal(String(c[(i + 1)..<close]))
                w.quoted = true
                i = close
            case "\"":
                var j = i + 1, s = ""
                while j < c.count, c[j] != "\"" {
                    if c[j] == "\\", j + 1 < c.count, "\"\\$`".contains(c[j + 1]) {
                        s.append(c[j + 1])
                        j += 2
                    } else if c[j] == "$" {
                        let (value, after) = expand(j)
                        s += value
                        j = after
                    } else {
                        s.append(c[j])
                        j += 1
                    }
                }
                guard j < c.count else { throw ShellError("unterminated quote") }
                literal(s)
                w.quoted = true
                i = j
            case "\\":
                if let next { literal(String(next)); i += 1 }
            case "$":
                let (value, after) = expand(i)
                literal(value)
                i = after - 1
            case "~" where !inWord && (next == nil || next == "/" || next!.isWhitespace):
                literal(home)
            case "*", "?", "[":
                w.text.append(ch)
                w.pattern.append(ch)
                w.globbed = true
                inWord = true
            case "|":
                end()
                tokens.append(.pipe)
            case "<":
                end()
                tokens.append(.redirect(.input))
            case ">":
                if inWord, w.text == "2", !w.quoted {
                    w = Word()
                    inWord = false
                    if next == ">" {
                        tokens.append(.redirect(.errorAppend))
                        i += 1
                    } else if next == "&", i + 2 < c.count, c[i + 2] == "1" {
                        tokens.append(.redirect(.errorToOutput))
                        i += 2
                    } else {
                        tokens.append(.redirect(.errorOutput))
                    }
                } else {
                    end()
                    if next == ">" {
                        tokens.append(.redirect(.append))
                        i += 1
                    } else {
                        tokens.append(.redirect(.output))
                    }
                }
            case "&" where next == ">":
                end()
                tokens.append(.redirect(.bothOutput))
                i += 1
            default:
                literal(String(ch))
            }
            i += 1
        }
        end()
        return tokens
    }

    static func escape(_ c: Character) -> String { "*?[]\\".contains(c) ? "\\" + String(c) : String(c) }

    static func hasGlob(_ pattern: Substring) -> Bool {
        var escaped = false
        for ch in pattern {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if "*?[".contains(ch) { return true }
        }
        return false
    }

    static func unescape(_ pattern: Substring) -> String {
        var out = "", escaped = false
        for ch in pattern {
            if !escaped, ch == "\\" { escaped = true; continue }
            out.append(ch)
            escaped = false
        }
        return out
    }
}
