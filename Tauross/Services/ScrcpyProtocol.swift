import Foundation

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
    func unsignedBE(at offset: Int, count: Int) -> UInt64 {
        self[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

/// Wire format pinned to scrcpy-server 3.3.4. See Resources/Licenses and README.
enum ScrcpyControl {
    static func key(_ code: UInt32, down: Bool) -> Data {
        var data = Data([0, down ? 0 : 1])
        data.appendBE(code)
        data.appendBE(UInt32(0))
        data.appendBE(UInt32(0))
        return data
    }
    static func text(_ text: String) -> Data {
        let bytes = Data(text.utf8)
        var data = Data([1])
        data.appendBE(UInt32(bytes.count))
        data.append(bytes)
        return data
    }
    static func touch(action: UInt8, x: Int, y: Int, width: Int, height: Int) -> Data {
        var data = Data([2, action])
        data.appendBE(UInt64.max - 1) // SC_POINTER_ID_GENERIC_FINGER
        data.appendBE(UInt32(clamping: x))
        data.appendBE(UInt32(clamping: y))
        data.appendBE(UInt16(clamping: width))
        data.appendBE(UInt16(clamping: height))
        data.appendBE(UInt16(action == 1 ? 0 : 0xffff))
        data.appendBE(UInt32(0))
        data.appendBE(UInt32(0))
        return data
    }
    static func scroll(x: Int, y: Int, width: Int, height: Int, dx: Double, dy: Double) -> Data {
        var data = Data([3])
        data.appendBE(UInt32(clamping: x)); data.appendBE(UInt32(clamping: y))
        data.appendBE(UInt16(clamping: width)); data.appendBE(UInt16(clamping: height))
        data.appendBE(Int16(max(-32767, min(32767, dx / 16 * 32767))))
        data.appendBE(Int16(max(-32767, min(32767, dy / 16 * 32767))))
        data.appendBE(UInt32(0))
        return data
    }
}

enum H264AnnexB {
    static func units(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(Int, Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, i + 3)); i += 3; continue }
                if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    starts.append((i, i + 4)); i += 4; continue
                }
            }
            i += 1
        }
        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            return start.1 < end ? Data(bytes[start.1..<end]) : nil
        }
    }
}
