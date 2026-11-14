import Foundation
import CoreFoundation

// MARK: - 支持的编码

enum TextEncodingKind: String, CaseIterable {
    case utf8      = "UTF-8"
    case utf8BOM   = "UTF-8 with BOM"
    case utf16LE   = "UTF-16 LE"
    case utf16BE   = "UTF-16 BE"
    case utf32LE   = "UTF-32 LE"
    case utf32BE   = "UTF-32 BE"
    case gb18030   = "GB18030 / GBK"
    case big5      = "Big5"
    case shiftJIS  = "Shift-JIS"
    case eucKR     = "EUC-KR"
    case latin1    = "ISO-8859-1"

    var displayName: String { rawValue }

    var bomBytes: [UInt8] {
        switch self {
        case .utf8BOM:  return [0xEF, 0xBB, 0xBF]
        case .utf16LE:  return [0xFF, 0xFE]
        case .utf16BE:  return [0xFE, 0xFF]
        case .utf32LE:  return [0xFF, 0xFE, 0x00, 0x00]
        case .utf32BE:  return [0x00, 0x00, 0xFE, 0xFF]
        default:        return []
        }
    }

    /// 该编码在保存时是否强制写出 BOM
    var alwaysWritesBOM: Bool {
        switch self {
        case .utf8BOM, .utf32LE, .utf32BE: return true
        default: return false
        }
    }

    /// 该编码是否为多字节变长编码（用于字节与字符映射提示）
    var isMultiByte: Bool {
        switch self {
        case .gb18030, .big5, .shiftJIS, .eucKR: return true
        default: return false
        }
    }

    var foundationEncoding: String.Encoding? {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16LE:        return .utf16LittleEndian
        case .utf16BE:        return .utf16BigEndian
        case .utf32LE:        return .utf32LittleEndian
        case .utf32BE:        return .utf32BigEndian
        case .latin1:         return .isoLatin1
        default:              return nil
        }
    }

    var ianaName: String? {
        switch self {
        case .gb18030:  return "GB18030"
        case .big5:     return "Big5"
        case .shiftJIS: return "Shift_JIS"
        case .eucKR:    return "EUC-KR"
        default:        return nil
        }
    }

    /// 可用于 NSString 解码/编码的编码
    var nsEncoding: String.Encoding? {
        if let e = foundationEncoding { return e }
        guard let iana = ianaName else { return nil }
        let cf = CFStringConvertIANACharSetNameToEncoding(iana as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        let raw = CFStringConvertEncodingToNSStringEncoding(cf)
        guard raw != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: raw)
    }

    static func fromNSEncoding(_ e: String.Encoding) -> TextEncodingKind? {
        return allCases.first { $0.nsEncoding?.rawValue == e.rawValue }
    }
}

// MARK: - 编解码

enum EncodingCodec {

    static func decode(_ data: Data, as kind: TextEncodingKind) -> String? {
        guard !data.isEmpty else { return "" }
        guard let enc = kind.nsEncoding else { return nil }
        var payload = data
        // 去除 BOM，避免解出 U+FEFF 前缀
        let bom = kind.bomBytes
        if !bom.isEmpty, payload.count >= bom.count, Array(payload.prefix(bom.count)) == bom {
            payload = payload.subdata(in: bom.count..<payload.count)
        }
        guard !payload.isEmpty else { return "" }
        return String(data: payload, encoding: enc)
    }

    static func encode(_ text: String, as kind: TextEncodingKind) -> Data? {
        guard let enc = kind.nsEncoding else { return nil }
        return text.data(using: enc, allowLossyConversion: false)
    }

    /// 大文件模式下的高速路径：UTF-8 直接用 String(decoding:)
    static func fastDecode(_ data: Data, as kind: TextEncodingKind) -> String? {
        if kind == .utf8 || kind == .utf8BOM {
            var payload = data
            if kind == .utf8BOM, payload.count >= 3, payload[payload.startIndex] == 0xEF {
                payload = payload.dropFirst(3)
            }
            return String(decoding: payload, as: UTF8.self)
        }
        return decode(data, as: kind)
    }
}

// MARK: - 编码探测

enum EncodingDetector {

    /// 读取文件头部样本并判断编码
    static func detect(url: URL, sampleSize: Int = 256 * 1024) -> (kind: TextEncodingKind, hasBOM: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (.utf8, false) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: sampleSize)) ?? Data()
        return detect(data: data)
    }

    static func detect(data: Data) -> (kind: TextEncodingKind, hasBOM: Bool) {
        if data.isEmpty { return (.utf8, false) }

        let bytes = [UInt8](data.prefix(8))

        // 1. BOM
        if bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xFE, bytes[2] == 0x00, bytes[3] == 0x00 { return (.utf32LE, true) }
        if bytes.count >= 4, bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0xFE, bytes[3] == 0xFF { return (.utf32BE, true) }
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { return (.utf8BOM, true) }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE { return (.utf16LE, true) }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF { return (.utf16BE, true) }

        // 2. 明显的二进制内容 : 直接交给调用方处理（按 UTF-8 尝试）
        if looksBinary(data) { return (.utf8, false) }

        // 3. 无 BOM 的 UTF-16 特征：奇数位大量 0
        if let kind = detectUTF16WithoutBOM(data) { return (kind, false) }

        // 4. 严格 UTF-8
        if String(data: data, encoding: .utf8) != nil { return (.utf8, false) }

        // 5. 中日韩编码回落：按 CJK 命中率加权评分择优
        var scores: [(TextEncodingKind, Int)] = []
        for kind in [TextEncodingKind.gb18030, .big5, .shiftJIS, .eucKR] {
            guard let decoded = EncodingCodec.decode(data, as: kind) else { continue }
            if decoded.unicodeScalars.contains(where: { $0.value == 0xFFFD }) { continue }
            let score = cjkScore(decoded)
            if score > 0 { scores.append((kind, score)) }
        }
        // GB18030 是超集，容易"假成功"，因此要求其得分明显高于其他候选才采用
        if let gb = scores.first(where: { $0.0 == .gb18030 }) {
            let maxOther = scores.filter { $0.0 != .gb18030 }.map { $0.1 }.max() ?? 0
            if Double(gb.1) >= Double(maxOther) * 1.2 { return (.gb18030, false) }
        }
        if let best = scores.max(by: { $0.1 < $1.1 }) { return (best.0, false) }

        // 6. 兜底
        if EncodingCodec.decode(data, as: .latin1) != nil { return (.latin1, false) }
        return (.utf8, false)
    }

    static func looksBinary(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let check = min(data.count, 8192)
        var zeroCount = 0
        var controlCount = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<check {
                let b = raw[i]
                if b == 0x00 { zeroCount += 1 }
                else if b < 0x09 || (b > 0x0D && b < 0x20) { controlCount += 1 }
            }
        }
        if zeroCount > check / 20 { return true }
        if controlCount > check / 10 { return true }
        return false
    }

    private static func detectUTF16WithoutBOM(_ data: Data) -> TextEncodingKind? {
        let check = min(data.count, 4096)
        guard check >= 8 else { return nil }
        var evenZero = 0, oddZero = 0
        var latinHigh = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<check {
                if raw[i] == 0 {
                    if i % 2 == 0 { evenZero += 1 } else { oddZero += 1 }
                }
            }
            for i in stride(from: 0, to: check - 1, by: 2) {
                if raw[i + 1] == 0 && raw[i] != 0 { latinHigh += 1 }
            }
        }
        let half = check / 2
        if oddZero > Int(Double(half) * 0.6) && evenZero < half / 10 { return .utf16LE }
        if evenZero > Int(Double(half) * 0.6) && oddZero < half / 10 { return .utf16BE }
        _ = latinHigh
        return nil
    }

    private static func cjkScore(_ s: String) -> Int {
        var score = 0
        var total = 0
        for scalar in s.unicodeScalars {
            total += 1
            if total > 4000 { break }
            switch scalar.value {
            case 0x4E00...0x9FFF:  score += 3   // CJK 统一表意文字（常用汉字）
            case 0x3000...0x303F:  score += 2   // CJK 标点
            case 0xFF00...0xFF65:  score += 2   // 全角标点
            case 0x3040...0x30FF:  score += 2   // 假名
            case 0xAC00...0xD7AF:  score += 2   // 韩文音节
            case 0xE000...0xF8FF:  score -= 4   // 私有使用区（乱码典型特征）
            case 0xF900...0xFAFF:  score -= 2   // 兼容表意文字
            case 0x3400...0x4DBF:  score -= 1   // 扩展 A（较生僻）
            default: break
            }
        }
        return score
    }

    /// 判断换行符风格（读取头部样本）
    static func detectNewline(url: URL) -> NewlineStyle {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .lf }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 65536)) ?? Data()
        if data.isEmpty { return .lf }
        var crlf = 0, lf = 0, cr = 0
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0D {
                if i + 1 < bytes.count && bytes[i + 1] == 0x0A { crlf += 1; i += 2; continue }
                cr += 1
            } else if bytes[i] == 0x0A {
                lf += 1
            }
            i += 1
        }
        if crlf >= lf && crlf >= cr && crlf > 0 { return .crlf }
        if cr > lf && cr > 0 { return .cr }
        return .lf
    }
}
