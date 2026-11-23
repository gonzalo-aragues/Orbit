import CoreGraphics
import Foundation

/// A small lossless WebP (VP8L) encoder. ImageIO can read WebP but not write it, so we do it ourselves:
/// subtract-green + a single "average of left and top" predictor, then per-channel Huffman coding.
enum WebPEncoder {
    static func encode(_ source: CGImage) -> Data? {
        var image = source
        if image.width > 16384 || image.height > 16384 {
            guard let scaled = ImageIOUtil.downscale(image, maxDimension: 16384) else { return nil }
            image = scaled
        }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let n = w * h

        var rgba = [UInt8](repeating: 0, count: n * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: ImageIOUtil.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // Un-premultiply and apply the subtract-green transform.
        var a = [UInt8](repeating: 255, count: n)
        var r = [UInt8](repeating: 0, count: n)
        var g = [UInt8](repeating: 0, count: n)
        var b = [UInt8](repeating: 0, count: n)
        var hasAlpha = false
        for i in 0..<n {
            let o = i * 4
            let al = Int(rgba[o + 3])
            var rr = Int(rgba[o]), gg = Int(rgba[o + 1]), bb = Int(rgba[o + 2])
            if al == 0 {
                rr = 0; gg = 0; bb = 0
            } else if al < 255 {
                rr = min(255, (rr * 255 + al / 2) / al)
                gg = min(255, (gg * 255 + al / 2) / al)
                bb = min(255, (bb * 255 + al / 2) / al)
            }
            if al < 255 { hasAlpha = true }
            a[i] = UInt8(al)
            g[i] = UInt8(gg)
            r[i] = UInt8(rr) &- UInt8(gg)
            b[i] = UInt8(bb) &- UInt8(gg)
        }

        // Predictor transform, mode 7: Average2(L, T). Row 0 uses L, column 0 uses T, pixel 0 uses 0xff000000.
        var ra = a, rr = r, rg = g, rb = b
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                if x == 0 && y == 0 {
                    ra[i] = a[i] &- 255
                    continue
                }
                let pa, pr, pg, pb: UInt8
                if y == 0 {
                    let l = i - 1
                    pa = a[l]; pr = r[l]; pg = g[l]; pb = b[l]
                } else if x == 0 {
                    let t = i - w
                    pa = a[t]; pr = r[t]; pg = g[t]; pb = b[t]
                } else {
                    let l = i - 1, t = i - w
                    pa = UInt8((Int(a[l]) + Int(a[t])) >> 1)
                    pr = UInt8((Int(r[l]) + Int(r[t])) >> 1)
                    pg = UInt8((Int(g[l]) + Int(g[t])) >> 1)
                    pb = UInt8((Int(b[l]) + Int(b[t])) >> 1)
                }
                ra[i] = a[i] &- pa
                rr[i] = r[i] &- pr
                rg[i] = g[i] &- pg
                rb[i] = b[i] &- pb
            }
        }

        var bw = BitWriter()
        bw.write(0x2f, 8)
        bw.write(w - 1, 14)
        bw.write(h - 1, 14)
        bw.write(hasAlpha ? 1 : 0, 1)
        bw.write(0, 3)

        // Transform 1: subtract green.
        bw.write(1, 1); bw.write(2, 2)
        // Transform 2: predictor with 512px blocks, every block using mode 7.
        bw.write(1, 1); bw.write(0, 2); bw.write(9 - 2, 3)
        bw.write(0, 1)                                     // sub-image: no colour cache
        writeSimple(&bw, symbol: 7)                         // green carries the mode
        writeSimple(&bw, symbol: 0)
        writeSimple(&bw, symbol: 0)
        writeSimple(&bw, symbol: 0)
        writeSimple(&bw, symbol: 0)
        bw.write(0, 1)                                     // no more transforms

        // Main image.
        bw.write(0, 1)                                     // no colour cache
        bw.write(0, 1)                                     // no meta prefix codes
        let green = PrefixCode(histogram(rg, alphabet: 280))
        let red = PrefixCode(histogram(rr, alphabet: 256))
        let blue = PrefixCode(histogram(rb, alphabet: 256))
        let alpha = PrefixCode(histogram(ra, alphabet: 256))
        green.writeHeader(&bw)
        red.writeHeader(&bw)
        blue.writeHeader(&bw)
        alpha.writeHeader(&bw)
        writeSimple(&bw, symbol: 0)                         // distance code, unused

        for i in 0..<n {
            green.put(rg[i], &bw)
            red.put(rr[i], &bw)
            blue.put(rb[i], &bw)
            alpha.put(ra[i], &bw)
        }
        bw.flush()

        var out = Data()
        let payload = bw.bytes
        let pad = payload.count & 1
        out.append(contentsOf: Array("RIFF".utf8))
        out.append(le32(4 + 8 + payload.count + pad))
        out.append(contentsOf: Array("WEBPVP8L".utf8))
        out.append(le32(payload.count))
        out.append(contentsOf: payload)
        if pad == 1 { out.append(0) }
        return out
    }

    // MARK: - Bits

    struct BitWriter {
        var bytes: [UInt8] = []
        private var acc: UInt64 = 0
        private var count = 0

        mutating func write(_ value: Int, _ bits: Int) {
            guard bits > 0 else { return }
            acc |= (UInt64(value) & ((1 << UInt64(bits)) - 1)) << UInt64(count)
            count += bits
            while count >= 8 {
                bytes.append(UInt8(acc & 0xff))
                acc >>= 8
                count -= 8
            }
        }

        mutating func flush() {
            if count > 0 { bytes.append(UInt8(acc & 0xff)) }
            acc = 0
            count = 0
        }
    }

    private static func le32(_ v: Int) -> Data {
        Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }

    private static func histogram(_ values: [UInt8], alphabet: Int) -> [Int] {
        var h = [Int](repeating: 0, count: alphabet)
        for v in values { h[Int(v)] += 1 }
        return h
    }

    private static func writeSimple(_ bw: inout BitWriter, symbol: Int) {
        bw.write(1, 1)          // simple code
        bw.write(0, 1)          // one symbol
        if symbol < 2 {
            bw.write(0, 1); bw.write(symbol, 1)
        } else {
            bw.write(1, 1); bw.write(symbol, 8)
        }
    }

    // MARK: - Huffman

    private static let codeLengthOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

    private struct PrefixCode {
        let lengths: [UInt8]
        let codes: [UInt32]
        let single: Int?

        init(_ freq: [Int]) {
            let used = freq.indices.filter { freq[$0] > 0 }
            if used.count <= 1 {
                single = used.first ?? 0
                lengths = []
                codes = []
            } else {
                single = nil
                lengths = WebPEncoder.huffmanLengths(freq, limit: 15)
                codes = WebPEncoder.canonicalCodes(lengths)
            }
        }

        func writeHeader(_ bw: inout BitWriter) {
            if let single {
                WebPEncoder.writeSimple(&bw, symbol: single)
                return
            }
            bw.write(0, 1)  // normal code
            var clFreq = [Int](repeating: 0, count: 19)
            for l in lengths { clFreq[Int(l)] += 1 }
            let clUsed = clFreq.filter { $0 > 0 }.count
            var clLengths = [UInt8](repeating: 0, count: 19)
            if clUsed == 1, let only = clFreq.firstIndex(where: { $0 > 0 }) {
                clLengths[only] = 1     // a lone symbol decodes with zero bits
            } else {
                clLengths = WebPEncoder.huffmanLengths(clFreq, limit: 7)
            }
            let clCodes = WebPEncoder.canonicalCodes(clLengths)
            bw.write(19 - 4, 4)
            for i in 0..<19 { bw.write(Int(clLengths[codeLengthOrder[i]]), 3) }
            bw.write(0, 1)  // max_symbol = alphabet size
            if clUsed > 1 {
                for l in lengths { bw.write(Int(clCodes[Int(l)]), Int(clLengths[Int(l)])) }
            }
        }

        @inline(__always) func put(_ symbol: UInt8, _ bw: inout BitWriter) {
            if single != nil { return }
            let s = Int(symbol)
            bw.write(Int(codes[s]), Int(lengths[s]))
        }
    }

    static func huffmanLengths(_ freq: [Int], limit: Int) -> [UInt8] {
        var f = freq
        while true {
            let lengths = buildLengths(f)
            if Int(lengths.max() ?? 0) <= limit { return lengths }
            f = f.map { $0 == 0 ? 0 : max(1, $0 / 2) }
        }
    }

    private static func buildLengths(_ freq: [Int]) -> [UInt8] {
        var lengths = [UInt8](repeating: 0, count: freq.count)
        let symbols = freq.indices.filter { freq[$0] > 0 }
        if symbols.isEmpty { return lengths }
        if symbols.count == 1 { lengths[symbols[0]] = 1; return lengths }

        var weight = symbols.map { freq[$0] }
        var parent = [Int](repeating: -1, count: symbols.count)
        var active = Array(0..<symbols.count)
        while active.count > 1 {
            active.sort { weight[$0] != weight[$1] ? weight[$0] < weight[$1] : $0 < $1 }
            let x = active.removeFirst(), y = active.removeFirst()
            let node = weight.count
            weight.append(weight[x] + weight[y])
            parent.append(-1)
            parent[x] = node
            parent[y] = node
            active.append(node)
        }
        for (leaf, symbol) in symbols.enumerated() {
            var depth = 0
            var p = parent[leaf]
            while p != -1 { depth += 1; p = parent[p] }
            lengths[symbol] = UInt8(depth)
        }
        return lengths
    }

    /// Canonical codes, bit-reversed so they can be written LSB-first.
    static func canonicalCodes(_ lengths: [UInt8]) -> [UInt32] {
        var blCount = [Int](repeating: 0, count: 16)
        for l in lengths where l > 0 { blCount[Int(l)] += 1 }
        var next = [Int](repeating: 0, count: 17)
        var code = 0
        for bits in 1...15 {
            code = (code + blCount[bits - 1]) << 1
            next[bits] = code
        }
        var codes = [UInt32](repeating: 0, count: lengths.count)
        for (s, l) in lengths.enumerated() where l > 0 {
            let len = Int(l)
            var c = UInt32(next[len])
            next[len] += 1
            var rev: UInt32 = 0
            for _ in 0..<len { rev = (rev << 1) | (c & 1); c >>= 1 }
            codes[s] = rev
        }
        return codes
    }
}
