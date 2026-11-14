import Foundation

/// 稀疏行索引：每隔 `stride` 行记录一次字节锚点，避免超大文件构建 [Int64] 全量行表。
/// 内存占用约为 行数/stride * 8 字节；按行查找时从锚点向后顺序扫描，最多扫描 stride 个换行。
final class LineIndex {

    let url: URL
    let fileSize: Int64
    let stride: Int

    private let handle: FileHandle?

    private(set) var totalLines: Int = 1
    private(set) var anchors: [Int64] = [0]
    private(set) var built = false
    private(set) var buildDuration: TimeInterval = 0

    private var cachedBlock = -1
    private var cachedOffsets: [Int64] = []

    init(url: URL, fileSize: Int64, stride: Int = 2048) {
        self.url = url
        self.fileSize = fileSize
        self.stride = stride
        self.handle = try? FileHandle(forReadingFrom: url)
    }

    /// 同步构建（应在后台线程调用）
    func build() {
        let startTime = Date()
        guard let handle = handle, fileSize > 0 else {
            totalLines = fileSize == 0 ? 1 : 1
            anchors = [0]
            built = true
            buildDuration = Date().timeIntervalSince(startTime)
            return
        }

        var anchorsOut: [Int64] = [0]
        var lineCount = 1
        var pos: Int64 = 0

        while pos < fileSize {
            let readSize = Int(min(Int64(1 << 18), fileSize - pos))
            guard readSize > 0, let data = try? handle.read(upToCount: readSize), !data.isEmpty else { break }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<raw.count {
                    if raw[i] == 0x0A {
                        lineCount += 1
                        if (lineCount - 1) % stride == 0 {
                            anchorsOut.append(pos + Int64(i) + 1)
                        }
                    }
                }
            }
            pos += Int64(data.count)
        }

        self.anchors = anchorsOut
        self.totalLines = lineCount
        self.built = true
        self.buildDuration = Date().timeIntervalSince(startTime)
    }

    /// 返回指定行所在的块内行起始偏移表；首元素是块第一行的起始偏移
    private func offsets(forBlock block: Int) -> [Int64] {
        if block == cachedBlock && !cachedOffsets.isEmpty { return cachedOffsets }
        guard block >= 0, block < anchors.count else { return [] }

        let start = anchors[block]
        let firstLine = block * stride
        let linesInBlock = max(0, min(stride, totalLines - firstLine))

        var offsetsOut: [Int64] = [start]
        guard linesInBlock > 0, let handle = handle else {
            cachedBlock = block
            cachedOffsets = offsetsOut
            return offsetsOut
        }

        let limit = (block + 1 < anchors.count) ? anchors[block + 1] : fileSize
        var pos = start
        var need = linesInBlock
        var iterations = 0

        do {
            try handle.seek(toOffset: UInt64(pos))
        } catch {
            cachedBlock = block
            cachedOffsets = offsetsOut
            return offsetsOut
        }

        while need > 0 && pos < limit && iterations < 1_000_000 {
            let remaining = limit - pos
            let readSize = Int(min(Int64(1 << 18), remaining))
            guard readSize > 0, let data = try? handle.read(upToCount: readSize), !data.isEmpty else { break }
            var found = 0
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<raw.count {
                    if raw[i] == 0x0A {
                        offsetsOut.append(pos + Int64(i) + 1)
                        found += 1
                        if found >= need { break }
                    }
                }
            }
            need -= found
            pos += Int64(data.count)
            iterations += 1
        }

        cachedBlock = block
        cachedOffsets = offsetsOut
        return offsetsOut
    }

    /// 行对应的原始字节区间（含行尾换行符）
    func byteRange(ofLine line: Int) -> Range<Int64>? {
        guard line >= 0, line < totalLines else { return nil }
        let block = line / stride
        let offsets = offsets(forBlock: block)
        let idx = line - block * stride
        guard idx < offsets.count else { return nil }

        let start = offsets[idx]
        let end: Int64
        if idx + 1 < offsets.count {
            end = offsets[idx + 1]
        } else if block + 1 < anchors.count {
            end = anchors[block + 1]
        } else {
            end = fileSize
        }
        guard end >= start else { return nil }
        return start..<end
    }

    /// 行号（0 基）对应的起始字节偏移
    func offset(ofLine line: Int) -> Int64? {
        return byteRange(ofLine: line)?.lowerBound
    }

    /// 给定字节偏移，估算其所在行号（用于跳转与状态栏）
    func lineNumber(forOffset offset: Int64) -> Int? {
        guard built else { return nil }
        var low = 0
        var high = anchors.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if anchors[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        let block = low
        let offsets = offsets(forBlock: block)
        var result = block * stride
        for i in 0..<offsets.count {
            if offsets[i] <= offset { result = block * stride + i } else { break }
        }
        return min(result, max(0, totalLines - 1))
    }

    func invalidateCache() {
        cachedBlock = -1
        cachedOffsets = []
    }
}
