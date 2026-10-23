// RFC 1950/1951 zlib stored-block writer + inflater (shared by PDF FlateDecode and enough for round-trips).

enum Zlib {
    static func stored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        var i = 0
        repeat {
            let n = min(65535, data.count - i)
            let final: UInt8 = i + n >= data.count ? 1 : 0
            out.append(final)
            out.append(UInt8(n & 255)); out.append(UInt8(n >> 8))
            out.append(UInt8(~n & 255)); out.append(UInt8((~n >> 8) & 255))
            out.append(contentsOf: data[i..<(i + n)])
            i += n
        } while i < data.count
        var a: UInt32 = 1, b: UInt32 = 0
        for v in data { a = (a + UInt32(v)) % 65521; b = (b + a) % 65521 }
        let adler = b << 16 | a
        out.append(contentsOf: [UInt8(adler >> 24), UInt8(adler >> 16 & 255),
                                UInt8(adler >> 8 & 255), UInt8(adler & 255)])
        return out
    }

    static func inflateZlib(_ input: [UInt8]) -> [UInt8]? {
        guard input.count > 6, input[0] & 0x0F == 8,
              (Int(input[0]) << 8 | Int(input[1])) % 31 == 0 else { return nil }
        return inflate(Array(input[2...]))
    }

    private struct Huffman { var count = [Int](repeating: 0, count: 16); var symbol: [Int] }
    private static func build(_ lengths: [Int]) -> Huffman {
        var h = Huffman(symbol: [Int](repeating: 0, count: lengths.count))
        for l in lengths { h.count[l] += 1 }
        var offs = [Int](repeating: 0, count: 16)
        for i in 1..<15 { offs[i + 1] = offs[i] + h.count[i] }
        for (s, l) in lengths.enumerated() where l != 0 { h.symbol[offs[l]] = s; offs[l] += 1 }
        return h
    }

    static func inflate(_ input: [UInt8]) -> [UInt8]? {
        var pos = 0, bitBuf = 0, bitCnt = 0
        var out = [UInt8]()
        func bits(_ n: Int) -> Int? {
            var val = bitBuf
            while bitCnt < n {
                guard pos < input.count else { return nil }
                val |= Int(input[pos]) << bitCnt; pos += 1; bitCnt += 8
            }
            bitBuf = val >> n; bitCnt -= n
            return val & ((1 << n) - 1)
        }
        func decode(_ h: Huffman) -> Int? {
            var code = 0, first = 0, index = 0
            for len in 1...15 {
                guard let b = bits(1) else { return nil }
                code |= b
                let count = h.count[len]
                if code - count < first { return h.symbol[index + (code - first)] }
                index += count; first += count; first <<= 1; code <<= 1
            }
            return nil
        }
        let lbase = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258]
        let lext = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0]
        let dbase = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
        let dext = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13]
        func codes(_ lc: Huffman, _ dc: Huffman) -> Bool {
            while true {
                guard let sym = decode(lc) else { return false }
                if sym < 256 { out.append(UInt8(sym)) }
                else if sym == 256 { return true }
                else {
                    let s = sym - 257
                    guard s < 29, let e = bits(lext[s]), let ds = decode(dc), ds < 30,
                          let de = bits(dext[ds]) else { return false }
                    let len = lbase[s] + e, dist = dbase[ds] + de
                    guard dist <= out.count else { return false }
                    for _ in 0..<len { out.append(out[out.count - dist]) }
                }
            }
        }
        var last = 0
        repeat {
            guard let l = bits(1), let type = bits(2) else { return nil }
            last = l
            switch type {
            case 0:
                bitBuf = 0; bitCnt = 0
                guard pos + 4 <= input.count else { return nil }
                let len = Int(input[pos]) | Int(input[pos + 1]) << 8
                pos += 4
                guard pos + len <= input.count else { return nil }
                out.append(contentsOf: input[pos..<(pos + len)]); pos += len
            case 1:
                var lens = [Int](repeating: 8, count: 288)
                for i in 144..<256 { lens[i] = 9 }; for i in 256..<280 { lens[i] = 7 }
                guard codes(build(lens), build([Int](repeating: 5, count: 30))) else { return nil }
            case 2:
                guard let nlen = bits(5), let ndist = bits(5), let ncode = bits(4) else { return nil }
                let order = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15]
                var cl = [Int](repeating: 0, count: 19)
                for i in 0..<(ncode + 4) { guard let v = bits(3) else { return nil }; cl[order[i]] = v }
                let clh = build(cl)
                var lengths = [Int](); let total = nlen + 257 + ndist + 1
                while lengths.count < total {
                    guard let sym = decode(clh) else { return nil }
                    if sym < 16 { lengths.append(sym) }
                    else {
                        var prev = 0, rep = 0
                        if sym == 16 { guard let lastLen = lengths.last, let r = bits(2) else { return nil }; prev = lastLen; rep = 3 + r }
                        else if sym == 17 { guard let r = bits(3) else { return nil }; rep = 3 + r }
                        else { guard let r = bits(7) else { return nil }; rep = 11 + r }
                        guard lengths.count + rep <= total else { return nil }
                        lengths.append(contentsOf: [Int](repeating: prev, count: rep))
                    }
                }
                guard codes(build(Array(lengths[0..<(nlen + 257)])),
                            build(Array(lengths[(nlen + 257)...]))) else { return nil }
            default: return nil
            }
        } while last == 0
        return out
    }
}
