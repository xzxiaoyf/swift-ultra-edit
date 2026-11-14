import AppKit

// MARK: - 语言

enum SyntaxLanguage: String, CaseIterable {
    case none = "纯文本"
    case python = "Python"
    case php = "PHP"
    case javascript = "JavaScript"
    case typescript = "TypeScript"
    case shell = "Shell"
    case ruby = "Ruby"
    case perl = "Perl"
    case lua = "Lua"
    case json = "JSON"
    case swift = "Swift"
    case cFamily = "C / C++"
    case java = "Java"
    case go = "Go"
    case rust = "Rust"
    case css = "CSS"
    case html = "HTML / XML"
    case sql = "SQL"
    case yaml = "YAML"
    case ini = "INI / TOML"
    case markdown = "Markdown"

    var displayName: String { rawValue }

    /// 参与「手动指定语言」菜单的项（不含纯文本）
    static var selectable: [SyntaxLanguage] { allCases.filter { $0 != .none } }

    /// 新建文件另存时的默认扩展名
    var defaultFileExtension: String {
        switch self {
        case .none: return "txt"
        case .python: return "py"
        case .php: return "php"
        case .javascript: return "js"
        case .typescript: return "ts"
        case .shell: return "sh"
        case .ruby: return "rb"
        case .perl: return "pl"
        case .lua: return "lua"
        case .json: return "json"
        case .swift: return "swift"
        case .cFamily: return "c"
        case .java: return "java"
        case .go: return "go"
        case .rust: return "rs"
        case .css: return "css"
        case .html: return "html"
        case .sql: return "sql"
        case .yaml: return "yml"
        case .ini: return "ini"
        case .markdown: return "md"
        }
    }

    // MARK: 探测

    static func detect(url: URL) -> SyntaxLanguage {
        let name = url.lastPathComponent.lowercased()
        if let lang = fromFileName(name) { return lang }
        // 无扩展名：看 shebang
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 256), !data.isEmpty,
               let head = String(data: data, encoding: .utf8) {
                return detectShebang(head)
            }
        }
        return .none
    }

    static func fromFileName(_ name: String) -> SyntaxLanguage? {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension

        // 特殊文件名
        if lower.hasPrefix("makefile") { return .shell }
        if lower == ".bashrc" || lower == ".zshrc" || lower == ".profile"
            || lower == ".bash_profile" || lower == ".zprofile" || lower == ".bash_aliases" {
            return .shell
        }
        if lower == "dockerfile" { return .shell }

        switch ext {
        case "py", "pyw", "pyi": return .python
        case "php", "php3", "php4", "php5", "phtml", "phps": return .php
        case "js", "mjs", "cjs", "jsx", "vue": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "sh", "bash", "zsh", "ksh", "command", "bashrc", "zshrc", "profile": return .shell
        case "rb", "rake", "gemspec", "podspec": return .ruby
        case "pl", "pm", "t": return .perl
        case "lua": return .lua
        case "json", "jsonc", "json5", "geojson": return .json
        case "swift": return .swift
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hxx", "m", "mm", "cs": return .cFamily
        case "java", "kt", "kts", "scala", "groovy": return .java
        case "go": return .go
        case "rs": return .rust
        case "css", "scss", "sass", "less": return .css
        case "html", "htm", "xhtml", "xml", "svg", "plist", "storyboard", "xib": return .html
        case "sql", "ddl", "dml": return .sql
        case "yml", "yaml": return .yaml
        case "ini", "cfg", "conf", "toml", "properties", "env": return .ini
        case "md", "markdown", "mdx", "rst": return .markdown
        case "txt", "log", "csv", "tsv": return .none
        default: return nil
        }
    }

    static func detectShebang(_ text: String) -> SyntaxLanguage {
        guard let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              firstLine.hasPrefix("#!") else { return .none }
        let line = firstLine.lowercased()
        if line.contains("python") { return .python }
        if line.contains("php") { return .php }
        if line.contains("node") || line.contains("deno") || line.contains("bun") { return .javascript }
        if line.contains("ruby") { return .ruby }
        if line.contains("perl") { return .perl }
        if line.contains("lua") { return .lua }
        if line.contains("bash") || line.contains("sh") || line.contains("zsh")
            || line.contains("ksh") || line.contains("fish") { return .shell }
        return .none
    }
}

// MARK: - Token

enum TokenKind: Equatable {
    case keyword
    case type
    case string
    case comment
    case number
    case function
    case variable
    case attribute
}

struct SyntaxToken {
    let range: NSRange
    let kind: TokenKind
}

/// 跨行状态：未闭合的注释结束符 / 字符串结束符
enum ScanState: Equatable {
    case normal
    case openComment(String)
    case openString(String)
}

// MARK: - 语言配置

struct LanguageSpec {
    var lineComments: [String] = []
    var blockComments: [(String, String)] = []
    var tripleQuotes: [(String, String)] = []
    var quoteChars: [unichar] = [34, 39]          // " '
    var sigils: [unichar] = []                     // $ @ %
    var decorator: unichar? = nil                  // @decorator
    var preprocessorChar: unichar? = nil           // C 的 #
    var keywords: Set<String> = []
    var types: Set<String> = []
    var caseSensitive: Bool = true
    var keyColon: Bool = false                     // JSON/YAML 的 "key":
    var markup: Bool = false                       // HTML 标签
    var headings: Bool = false                     // Markdown 标题

    static let nameFollowers: Set<String> = [
        "def", "class", "function", "func", "fn", "sub", "struct", "enum",
        "interface", "trait", "impl", "type", "module", "namespace", "package",
        "protocol", "extension", "record", "object"
    ]
    static let classLike: Set<String> = [
        "class", "struct", "enum", "interface", "trait", "type", "protocol",
        "impl", "namespace", "module", "package", "extension", "record", "object"
    ]
}

private func setOf(_ s: String) -> Set<String> {
    return Set(s.split(separator: " ").map(String.init))
}

extension SyntaxLanguage {

    var spec: LanguageSpec? {
        var spec = LanguageSpec()
        switch self {
        case .none:
            return nil
        case .python:
            spec.lineComments = ["#"]
            spec.tripleQuotes = [("\"\"\"", "\"\"\""), ("'''", "'''")]
            spec.decorator = 64               // @
            spec.keywords = setOf("""
            and as assert async await break class continue def del elif else except finally for from \
            global if import in is lambda nonlocal not or pass raise return try while with yield \
            True False None self match case
            """)
            spec.types = setOf("""
            int float str bool list dict set tuple bytes bytearray object type complex frozenset range \
            Exception ValueError TypeError KeyError IndexError RuntimeError
            """)
        case .php:
            spec.lineComments = ["//", "#"]
            spec.blockComments = [("/*", "*/")]
            spec.sigils = [36]
            spec.keywords = setOf("""
            abstract and array as break callable case catch class clone const continue declare default \
            do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends \
            final finally fn for foreach function global goto if implements include include_once \
            instanceof insteadof interface isset list match namespace new or print private protected \
            public readonly require require_once return static switch throw trait try unset use var \
            while xor yield true false null
            """)
            spec.types = setOf("int float string bool array object mixed void never self parent iterable")
        case .javascript:
            spec.lineComments = ["//"]
            spec.blockComments = [("/*", "*/")]
            spec.quoteChars = [34, 39, 96]
            spec.decorator = 64
            spec.keywords = setOf("""
            break case catch class const continue debugger default delete do else export extends \
            finally for function if import in instanceof let new return super switch this throw try \
            typeof var void while with yield async await of static get set true false null undefined \
            from as
            """)
            spec.types = setOf("""
            Array Object String Number Boolean Function Promise Map Set Symbol JSON Math console Date \
            RegExp Error window document
            """)
            spec.caseSensitive = true
        case .typescript:
            spec.lineComments = ["//"]
            spec.blockComments = [("/*", "*/")]
            spec.quoteChars = [34, 39, 96]
            spec.decorator = 64
            spec.keywords = setOf("""
            break case catch class const continue debugger default delete do else export extends \
            finally for function if import in instanceof let new return super switch this throw try \
            typeof var void while with yield async await of static get set true false null undefined \
            from as interface type enum implements namespace declare readonly abstract public private \
            protected any unknown never keyof infer satisfies
            """)
            spec.types = setOf("""
            string number boolean object symbol bigint void any unknown never Array Object Promise Map \
            Set Record Partial Readonly Date RegExp
            """)
        case .shell:
            spec.lineComments = ["#"]
            spec.quoteChars = [34, 39, 96]
            spec.sigils = [36]
            spec.keywords = setOf("""
            if then else elif fi for while until do done case esac function select in time return exit \
            export local readonly declare unset shift eval exec source alias echo printf cd test break \
            continue true false set trap wait read
            """)
        case .ruby:
            spec.lineComments = ["#"]
            spec.quoteChars = [34, 39, 96]
            spec.sigils = [36, 64, 37]
            spec.keywords = setOf("""
            def end class module if elsif else unless while until for in do return yield begin rescue \
            ensure raise require require_relative attr_accessor attr_reader attr_writer puts print nil \
            true false self super lambda proc then and or not new
            """)
        case .perl:
            spec.lineComments = ["#"]
            spec.quoteChars = [34, 39, 96]
            spec.sigils = [36, 64, 37]
            spec.keywords = setOf("""
            my our local sub if else elsif unless while for foreach return use require package print say \
            undef true false last next redo
            """)
            spec.types = setOf("int str")
        case .lua:
            spec.lineComments = ["--"]
            spec.blockComments = [("--[[", "]]")]
            spec.keywords = setOf("""
            and break do else elseif end false for function goto if in local nil not or repeat return \
            then true until while
            """)
        case .json:
            spec.lineComments = ["//"]
            spec.blockComments = [("/*", "*/")]
            spec.keywords = setOf("true false null")
            spec.keyColon = true
        case .swift:
            spec.lineComments = ["//"]
            spec.blockComments = [("/*", "*/")]
            spec.decorator = 64
            spec.keywords = setOf("""
            class struct enum protocol extension func var let if else guard switch case default for in \
            while repeat return import public private internal fileprivate open static final override \
            init deinit self super nil true false try catch throw throws async await some any where \
            typealias associatedtype lazy mutating nonmutating required convenience subscript operator \
            precedencegroup rethrows do defer
            """)
            spec.types = setOf("""
            Int String Double Float Bool Array Dictionary Set Optional Character Void Any Error Result \
            CGFloat CGPoint CGRect CGSize URL Data Date
            """)
        case .cFamily:
            spec.lineComments = ["//"]
            spec.blockComments = [("/*", "*/")]
            spec.preprocessorChar = 35        // #
            spec.keywords = setOf("""
            auto break case char const continue default do double else enum extern float for goto if \
            inline int long register restrict return short signed sizeof static struct switch typedef \
            union unsigned void volatile while bool true false nullptr class public private protected \
            virtual template typename namespace using new delete this operator friend explicit \
            constexpr noexcept override final
            """)
            spec.types = setOf("""
            size_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t FILE std string vector
            """)
        case .java:
            spec.lineComments = ["//"]
            spec.blockComments = [("/*", "*/")]
            spec.decorator = 64
            spec.keywords = setOf("""
            abstract assert boolean break byte case catch char class const continue default do double \
            else enum extends final finally float for goto if implements import instanceof int \
            interface long native new package private protected public return short static strictfp \
            super switch synchronized this throw throws transient try void volatile while var record \
            sealed permits yield true false null
            """)
            spec.types = setOf("String Integer Long Double Float Boolean Object List Map Set ArrayList HashMap")
        case .go:
            spec.lineComments = ["//"]
            spec.blockComments = [("/*", "*/")]
            spec.keywords = setOf("""
            break case chan const continue default defer else fallthrough for func go goto if import \
            interface map package range return select struct switch type var nil true false iota
            """)
            spec.types = setOf("int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float32 float64 string bool byte rune error any")
        case .rust:
            spec.lineComments = ["//"]
            spec.blockComments = [("/*", "*/")]
            spec.decorator = 35
            spec.keywords = setOf("""
            as break const continue crate else enum extern false fn for if impl in let loop match mod \
            move mut pub ref return self Self static struct super trait true type unsafe use where \
            while async await dyn box
            """)
            spec.types = setOf("""
            i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 f32 f64 bool char str String Vec Option Result Box \
            Rc Arc
            """)
        case .css:
            spec.blockComments = [("/*", "*/")]
            spec.decorator = 64
            spec.keywords = setOf("@media @import @font-face @keyframes @supports @charset")
        case .html:
            spec.blockComments = [("<!--", "-->")]
            spec.markup = true
        case .sql:
            spec.lineComments = ["--"]
            spec.blockComments = [("/*", "*/")]
            spec.caseSensitive = false
            spec.keywords = setOf("""
            select from where insert into values update set delete create table alter drop index view \
            join left right inner outer full on group by order having limit offset as and or not null \
            is in like between distinct union all exists case when then else end primary key foreign \
            references default unique auto_increment database if begin commit rollback
            """)
            spec.types = setOf("int integer varchar char text date datetime timestamp decimal float double boolean blob")
        case .yaml:
            spec.lineComments = ["#"]
            spec.keywords = setOf("true false null yes no on off")
            spec.keyColon = true
        case .ini:
            spec.lineComments = ["#", ";"]
            spec.keyColon = true
        case .markdown:
            spec.headings = true
            spec.blockComments = [("```", "```")]
            spec.quoteChars = [96]
        }
        return spec
    }
}

// MARK: - 分词器

final class SyntaxTokenizer {

    let spec: LanguageSpec
    private let nameFollowers = LanguageSpec.nameFollowers
    private let classLike = LanguageSpec.classLike

    init(spec: LanguageSpec) {
        self.spec = spec
    }

    // MARK: 字符判定

    private func isDigit(_ c: unichar) -> Bool { return c >= 48 && c <= 57 }

    private func isIdentStart(_ c: unichar) -> Bool {
        if c >= 65 && c <= 90 { return true }
        if c >= 97 && c <= 122 { return true }
        if c == 95 || c == 36 { return true }
        return c > 127
    }

    private func isIdentBody(_ c: unichar) -> Bool { return isIdentStart(c) || isDigit(c) }

    private func isSpace(_ c: unichar) -> Bool { return c == 32 || c == 9 }

    private func matches(_ s: String, _ ns: NSString, at i: Int, limit: Int) -> Bool {
        let len = s.utf16.count
        guard len > 0, i + len <= limit else { return false }
        let target = s as NSString
        for k in 0..<len where ns.character(at: i + k) != target.character(at: k) { return false }
        return true
    }

    private func findToken(_ token: String, _ ns: NSString, from: Int, to: Int) -> Int? {
        guard to > from, token.utf16.count > 0 else { return nil }
        let r = ns.range(of: token, options: [], range: NSRange(location: from, length: to - from))
        return r.location == NSNotFound ? nil : r.location
    }

    /// 查找未转义的引号
    private func findUnescaped(_ quote: unichar, _ ns: NSString, from: Int, to: Int) -> Int? {
        var i = from
        while i < to {
            let c = ns.character(at: i)
            if c == 92 { i += 2; continue }
            if c == quote { return i }
            i += 1
        }
        return nil
    }

    // MARK: 行分词

    /// 对 [start, end) 区间（一行，不含换行符）分词，state 跨行传递
    func tokenizeLine(_ ns: NSString, start: Int, end: Int, state: inout ScanState) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        guard end > start else { return tokens }

        var i = start

        // 1) 续行状态
        switch state {
        case .openComment(let term):
            if let idx = findToken(term, ns, from: start, to: end) {
                let stop = idx + term.utf16.count
                tokens.append(SyntaxToken(range: NSRange(location: start, length: stop - start), kind: .comment))
                i = stop
                state = .normal
            } else {
                tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: .comment))
                return tokens
            }
        case .openString(let term):
            let found: Int?
            if term.utf16.count == 1, let q = term.utf16.first {
                found = findUnescaped(q, ns, from: start, to: end)
            } else {
                let idx = findToken(term, ns, from: start, to: end)
                found = idx.map { $0 + term.utf16.count }
            }
            if let close = found {
                tokens.append(SyntaxToken(range: NSRange(location: start, length: close - start), kind: .string))
                i = close
                state = .normal
            } else {
                tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: .string))
                return tokens
            }
        case .normal:
            break
        }

        var onlySpaceSoFar = (i == start)
        var lastKeyword: String? = nil

        while i < end {
            let c = ns.character(at: i)

            if isSpace(c) { i += 1; continue }

            // 行注释
            for marker in spec.lineComments where matches(marker, ns, at: i, limit: end) {
                tokens.append(SyntaxToken(range: NSRange(location: i, length: end - i), kind: .comment))
                return tokens
            }

            // C 家族预处理指令：行首 # 开头的整行
            if let pc = spec.preprocessorChar, c == pc, onlySpaceSoFar {
                tokens.append(SyntaxToken(range: NSRange(location: i, length: end - i), kind: .attribute))
                return tokens
            }

            // 块注释
            var handledBlock = false
            for (open, close) in spec.blockComments where matches(open, ns, at: i, limit: end) {
                let from = i + open.utf16.count
                if let idx = findToken(close, ns, from: from, to: end) {
                    let stop = idx + close.utf16.count
                    tokens.append(SyntaxToken(range: NSRange(location: i, length: stop - i), kind: .comment))
                    i = stop
                } else {
                    tokens.append(SyntaxToken(range: NSRange(location: i, length: end - i), kind: .comment))
                    state = .openComment(close)
                    return tokens
                }
                handledBlock = true
                break
            }
            if handledBlock {
                onlySpaceSoFar = false
                continue
            }

            // 三引号
            var handledTriple = false
            for (open, close) in spec.tripleQuotes where matches(open, ns, at: i, limit: end) {
                let from = i + open.utf16.count
                if let idx = findToken(close, ns, from: from, to: end) {
                    let stop = idx + close.utf16.count
                    tokens.append(SyntaxToken(range: NSRange(location: i, length: stop - i), kind: .string))
                    i = stop
                } else {
                    tokens.append(SyntaxToken(range: NSRange(location: i, length: end - i), kind: .string))
                    state = .openString(close)
                    return tokens
                }
                handledTriple = true
                break
            }
            if handledTriple {
                onlySpaceSoFar = false
                continue
            }

            // Markdown 标题
            if spec.headings, onlySpaceSoFar, c == 35 {   // #
                tokens.append(SyntaxToken(range: NSRange(location: i, length: end - i), kind: .keyword))
                return tokens
            }

            // HTML 标签名
            if spec.markup, c == 60 {   // <
                var j = i + 1
                if j < end, ns.character(at: j) == 47 { j += 1 }   // /
                let nameStart = j
                while j < end {
                    let d = ns.character(at: j)
                    if isIdentBody(d) || d == 45 || d == 58 { j += 1 } else { break }
                }
                if j > nameStart {
                    tokens.append(SyntaxToken(range: NSRange(location: i, length: j - i), kind: .keyword))
                    i = j
                    onlySpaceSoFar = false
                    continue
                }
            }

            // 字符串
            if spec.quoteChars.contains(c) {
                var tokenKind = TokenKind.string
                if let close = findUnescaped(c, ns, from: i + 1, to: end) {
                    let stop = close + 1
                    if spec.keyColon {
                        // JSON/YAML：字符串后紧跟冒号 → 键名
                        var k = stop
                        while k < end, isSpace(ns.character(at: k)) { k += 1 }
                        if k < end, ns.character(at: k) == 58 { tokenKind = .attribute }
                    }
                    tokens.append(SyntaxToken(range: NSRange(location: i, length: stop - i), kind: tokenKind))
                    i = stop
                } else {
                    tokens.append(SyntaxToken(range: NSRange(location: i, length: end - i), kind: .string))
                    state = .openString(String(UnicodeScalar(c)!))
                    return tokens
                }
                onlySpaceSoFar = false
                continue
            }

            // 变量前缀 $ @ %
            if spec.sigils.contains(c) {
                // ${...}
                if i + 1 < end, ns.character(at: i + 1) == 123 {   // {
                    if let close = findUnescaped(125, ns, from: i + 1, to: end) {
                        tokens.append(SyntaxToken(range: NSRange(location: i, length: close + 1 - i), kind: .variable))
                        i = close + 1
                        onlySpaceSoFar = false
                        continue
                    }
                }
                if i + 1 < end {
                    let n = ns.character(at: i + 1)
                    if isIdentStart(n) {
                        var j = i + 1
                        while j < end, isIdentBody(ns.character(at: j)) { j += 1 }
                        tokens.append(SyntaxToken(range: NSRange(location: i, length: j - i), kind: .variable))
                        i = j
                        onlySpaceSoFar = false
                        continue
                    }
                    // shell 的 $1 $? $@ $! $# $* $-
                    if c == 36, isDigit(n) || n == 63 || n == 33 || n == 42 || n == 35 || n == 45 || n == 64 {
                        tokens.append(SyntaxToken(range: NSRange(location: i, length: 2), kind: .variable))
                        i += 2
                        onlySpaceSoFar = false
                        continue
                    }
                }
            }

            // 装饰器 @name
            if let dec = spec.decorator, c == dec, i + 1 < end, isIdentStart(ns.character(at: i + 1)) {
                var j = i + 1
                while j < end, isIdentBody(ns.character(at: j)) { j += 1 }
                tokens.append(SyntaxToken(range: NSRange(location: i, length: j - i), kind: .attribute))
                i = j
                onlySpaceSoFar = false
                continue
            }

            // 数字
            if isDigit(c) {
                var j = i
                while j < end {
                    let d = ns.character(at: j)
                    if isIdentBody(d) || d == 46 { j += 1; continue }
                    if (d == 43 || d == 45), j > i {
                        let prev = ns.character(at: j - 1) | 32
                        if prev == 101 { j += 1; continue }   // e+ / e-
                    }
                    break
                }
                tokens.append(SyntaxToken(range: NSRange(location: i, length: j - i), kind: .number))
                i = j
                onlySpaceSoFar = false
                continue
            }

            // 标识符
            if isIdentStart(c) {
                var j = i
                while j < end, isIdentBody(ns.character(at: j)) { j += 1 }
                let range = NSRange(location: i, length: j - i)
                let word = ns.substring(with: range)
                let key = spec.caseSensitive ? word : word.lowercased()
                var kind: TokenKind? = nil

                if spec.keywords.contains(key) {
                    kind = .keyword
                    lastKeyword = key
                } else if spec.types.contains(key) {
                    kind = .type
                    lastKeyword = nil
                } else if let last = lastKeyword, nameFollowers.contains(last) {
                    kind = classLike.contains(last) ? .type : .function
                    lastKeyword = nil
                } else {
                    lastKeyword = nil
                    var k = j
                    while k < end, isSpace(ns.character(at: k)) { k += 1 }
                    if k < end, ns.character(at: k) == 40 { kind = .function }   // (
                }
                if let k = kind {
                    tokens.append(SyntaxToken(range: range, kind: k))
                }
                i = j
                onlySpaceSoFar = false
                continue
            }

            // 其余字符（运算符、括号等）不着色
            onlySpaceSoFar = false
            i += 1
        }

        return tokens
    }

    /// 全文分词（返回绝对 NSRange）
    func tokenizeAll(_ text: String) -> [SyntaxToken] {
        let ns = text as NSString
        var tokens: [SyntaxToken] = []
        var state = ScanState.normal
        var idx = 0
        let len = ns.length
        while idx < len {
            let lineRange = ns.lineRange(for: NSRange(location: idx, length: 0))
            var contentEnd = lineRange.location + lineRange.length
            while contentEnd > lineRange.location {
                let c = ns.character(at: contentEnd - 1)
                if c == 10 || c == 13 { contentEnd -= 1 } else { break }
            }
            tokens.append(contentsOf: tokenizeLine(ns, start: lineRange.location, end: contentEnd, state: &state))
            if lineRange.length == 0 { break }
            idx = lineRange.location + lineRange.length
        }
        return tokens
    }
}

// MARK: - 高亮器

final class SyntaxHighlighter {

    static let shared = SyntaxHighlighter()

    /// 文本超过该长度时只高亮可视区域，避免卡顿
    static let fullHighlightLimit = 400_000

    private var tokenizers: [SyntaxLanguage: SyntaxTokenizer] = [:]

    func tokenizer(for language: SyntaxLanguage) -> SyntaxTokenizer? {
        guard let spec = language.spec else { return nil }
        if let t = tokenizers[language] { return t }
        let t = SyntaxTokenizer(spec: spec)
        tokenizers[language] = t
        return t
    }

    func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: return Theme.syntaxKeyword
        case .type: return Theme.syntaxType
        case .string: return Theme.syntaxString
        case .comment: return Theme.syntaxComment
        case .number: return Theme.syntaxNumber
        case .function: return Theme.syntaxFunction
        case .variable: return Theme.syntaxVariable
        case .attribute: return Theme.syntaxAttribute
        }
    }

    func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        return [
            .font: font,
            .foregroundColor: Theme.editorText,
            .paragraphStyle: Theme.codeParagraphStyle()
        ]
    }

    /// 取 tokens。range 为 nil 时全文，否则只处理该区间（区间外偏移量会平移）。
    func tokens(in text: String, language: SyntaxLanguage, range: NSRange?) -> [SyntaxToken] {
        guard let tokenizer = tokenizer(for: language) else { return [] }
        guard let r = range else { return tokenizer.tokenizeAll(text) }
        let ns = text as NSString
        guard r.location >= 0, r.location + r.length <= ns.length, r.length > 0 else { return [] }
        let sub = ns.substring(with: r)
        var tokens: [SyntaxToken] = []
        var state = ScanState.normal
        let subNS = sub as NSString
        var idx = 0
        while idx < subNS.length {
            let lineRange = subNS.lineRange(for: NSRange(location: idx, length: 0))
            var contentEnd = lineRange.location + lineRange.length
            while contentEnd > lineRange.location {
                let c = subNS.character(at: contentEnd - 1)
                if c == 10 || c == 13 { contentEnd -= 1 } else { break }
            }
            let lineTokens = tokenizer.tokenizeLine(subNS, start: lineRange.location, end: contentEnd, state: &state)
            for t in lineTokens {
                tokens.append(SyntaxToken(range: NSRange(location: t.range.location + r.location,
                                                       length: t.range.length), kind: t.kind))
            }
            if lineRange.length == 0 { break }
            idx = lineRange.location + lineRange.length
        }
        return tokens
    }

    /// 把高亮应用到 NSTextStorage 的指定区间（range 为 nil 表示全文）
    func apply(to storage: NSTextStorage,
               text: String,
               language: SyntaxLanguage,
               font: NSFont,
               range: NSRange?) {
        let length = storage.length
        let target = range ?? NSRange(location: 0, length: length)
        guard target.length > 0, target.location >= 0, target.location + target.length <= length else { return }

        let tokens = self.tokens(in: text, language: language, range: range)

        storage.beginEditing()
        storage.setAttributes(baseAttributes(font: font), range: target)
        for t in tokens {
            let r = NSIntersectionRange(t.range, target)
            guard r.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: color(for: t.kind), range: r)
        }
        storage.endEditing()
    }

    /// 仅恢复基础样式（关闭高亮时使用）
    func reset(to storage: NSTextStorage, font: NSFont, range: NSRange?) {
        let target = range ?? NSRange(location: 0, length: storage.length)
        guard target.length > 0, target.location + target.length <= storage.length else { return }
        storage.beginEditing()
        storage.setAttributes(baseAttributes(font: font), range: target)
        storage.endEditing()
    }
}
