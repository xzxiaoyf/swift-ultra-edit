import Foundation

/// 十六进制模式的数据源：按需读取 + 字节覆盖层。
/// 保存时只把被修改的字节写回原文件，避免整文件重写。
final class HexFileSource {

    let url: URL
    private(set) var size: Int64
    private let handle: FileHandle?

    private(set) var overrides: [Int64: UInt8] = [:]

    private var cacheRange: Range<Int64> = 0..<0
    private var cacheData: Data = Data()
    private let cacheChunk: Int64 = 256 * 1024

    var isDirty: Bool { !overrides.isEmpty }
    var changeCount: Int { overrides.count }

    var totalRows: Int {
        let per = 16
        return Int((size + Int64(per) - 1) / Int64(per))
    }

    init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        self.url = url
        self.handle = h
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - 读取

    private func fillCache(around offset: Int64) {
        guard let h = handle, size > 0 else { return }
        let start = max(0, (offset / cacheChunk) * cacheChunk - cacheChunk)
        let end = min(size, start + cacheChunk * 2)
        guard end > start else { return }
        do {
            try h.seek(toOffset: UInt64(start))
            if let d = try h.read(upToCount: Int(end - start)), !d.isEmpty {
                cacheRange = start..<(start + Int64(d.count))
                cacheData = d
            }
        } catch {
            cacheRange = 0..<0
            cacheData = Data()
        }
    }

    func rawByte(at offset: Int64) -> UInt8 {
        guard offset >= 0, offset < size else { return 0 }
        if !cacheRange.contains(offset) || cacheData.isEmpty {
            fillCache(around: offset)
        }
        guard cacheRange.contains(offset) else { return 0 }
        let idx = Int(offset - cacheRange.lowerBound)
        guard idx >= 0, idx < cacheData.count else { return 0 }
        return cacheData[cacheData.startIndex + idx]
    }

    func byte(at offset: Int64) -> UInt8 {
        if let v = overrides[offset] { return v }
        return rawByte(at: offset)
    }

    /// 读取 [offset, offset+count) 的显示字节（已应用覆盖层）
    func bytes(at offset: Int64, count: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        for i in 0..<count {
            let o = offset + Int64(i)
            if o >= size { break }
            out.append(byte(at: o))
        }
        return out
    }

    /// 读取一段连续数据用于复制
    func data(for range: Range<Int64>) -> Data {
        var out = Data()
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            let end = min(cursor + 4096, range.upperBound)
            var chunk = Data()
            for o in cursor..<end { chunk.append(byte(at: o)) }
            out.append(chunk)
            cursor = end
        }
        return out
    }

    // MARK: - 编辑

    func setByte(_ value: UInt8, at offset: Int64) {
        guard offset >= 0, offset < size else { return }
        if rawByte(at: offset) == value {
            overrides.removeValue(forKey: offset)
        } else {
            overrides[offset] = value
        }
    }

    func resetByte(at offset: Int64) {
        overrides.removeValue(forKey: offset)
    }

    func resetAll() {
        overrides.removeAll()
    }

    // MARK: - 保存

    func save(to targetURL: URL? = nil) throws {
        let target = targetURL ?? url
        guard !overrides.isEmpty else { return }

        let sameFile = target.standardizedFileURL == url.standardizedFileURL
        if sameFile {
            guard let h = try? FileHandle(forWritingTo: target) else {
                throw NSError(domain: "SwiftUltraEdit", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "无法写入文件 \(target.path)"])
            }
            let sorted = overrides.sorted { $0.key < $1.key }
            for (offset, value) in sorted {
                try h.seek(toOffset: UInt64(offset))
                try h.write(contentsOf: Data([value]))
            }
            try h.close()
        } else {
            // 另存为：整文件复制后打补丁
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: url, to: target)
            guard let h = try? FileHandle(forWritingTo: target) else {
                throw NSError(domain: "SwiftUltraEdit", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "无法写入文件 \(target.path)"])
            }
            for (offset, value) in overrides.sorted(by: { $0.key < $1.key }) {
                try h.seek(toOffset: UInt64(offset))
                try h.write(contentsOf: Data([value]))
            }
            try h.close()
        }
    }

    func reload() {
        overrides.removeAll()
        cacheRange = 0..<0
        cacheData = Data()
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            size = (attrs[.size] as? NSNumber)?.int64Value ?? size
        }
    }
}
