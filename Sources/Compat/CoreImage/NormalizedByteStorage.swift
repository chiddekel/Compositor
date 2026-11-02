/// Lossless storage selection for float rasters originating from normalized byte pixels.
enum NormalizedByteStorage {
    private static let decoded: [Float] = (0...255).map { Float($0) / 255 }

    static func encode(_ values: [Float]) -> [UInt8]? {
        var valid = true
        let bytes = [UInt8](unsafeUninitializedCapacity: values.count) { output, initialized in
            values.withUnsafeBufferPointer { source in
                decoded.withUnsafeBufferPointer { table in
                    for i in 0..<source.count {
                        let value = source[i]
                        guard value >= 0, value <= 1 else { valid = false; break }
                        let byte = Int(value * 255 + 0.5)
                        // A bitwise comparison also rejects negative zero and any approximate match.
                        guard table[byte].bitPattern == value.bitPattern else { valid = false; break }
                        output[i] = UInt8(byte)
                    }
                }
            }
            initialized = valid ? values.count : 0
        }
        return valid ? bytes : nil
    }
}
