import Foundation
import CryptoKit
import Testing
@testable import Compositor

struct CubeNativeReferenceTests {
    private struct Reference: Decodable {
        struct Buffer: Decodable {
            let base64: Data
            let sha256: String
        }
        struct Sample: Decodable {
            let dimension: Int
            let kind: String, fixture: String, inputSHA256: String, cubeSHA256: String
            let native: Buffer
        }
        let schema: Int, nativeRun: Int, width: Int, height: Int
        let nativeUnfusedDifferentComponents: Int
        let platform: String
        let cases: [Sample]
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func cube(_ dimension: Int, kind: String) -> Data {
        if kind.hasPrefix("hue") {
            let amount = Double(kind.dropFirst(3))!
            return HueSaturationFilter.cube(HueSaturationSettings(hue: amount, saturation: amount))
        }
        var state = UInt32(0x9e3779b9) ^ UInt32(dimension)
        func randomValue() -> Float {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return Float(Double(state) / Double(UInt32.max))
        }
        var values: [Float] = []
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            if kind == "identity" {
                values += [Float(Double(r) / Double(dimension - 1)), Float(Double(g) / Double(dimension - 1)),
                    Float(Double(b) / Double(dimension - 1)), 1]
            } else {
                values += [randomValue(), randomValue(), randomValue(), 1]
            }
        } } }
        return values.withUnsafeBytes { Data($0) }
    }

    @Test func portableCubeMatchesNativeArmArithmetic() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native-cube-reference.json")
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        #expect(reference.schema == 1 && reference.platform == "Darwin")
        #expect(reference.nativeRun == 40323679177 && reference.cases.count == 22)
        #expect(reference.nativeUnfusedDifferentComponents == 3)
        for sample in reference.cases {
            var pixels: [UInt8] = []
            for y in 0..<reference.height { for x in 0..<reference.width {
                let a = sample.fixture == "opaque" ? 255 : (17 * x + 29 * y) % 256
                pixels += [UInt8((x * 255 / 95) * a / 255), UInt8((y * 255 / 71) * a / 255), UInt8(100 * a / 255), UInt8(a)]
            } }
            #expect(hash(Data(pixels)) == sample.inputSHA256)
            let table = cube(sample.dimension, kind: sample.kind)
            #expect(hash(table) == sample.cubeSHA256)
            #expect(hash(sample.native.base64) == sample.native.sha256)
            table.withUnsafeBytes { entries in
                pixels.withUnsafeMutableBufferPointer { output in
                    cube_apply(output.baseAddress!, reference.width * reference.height,
                        entries.bindMemory(to: Float.self).baseAddress!, Int32(sample.dimension))
                }
            }
            let differences = zip(pixels, sample.native.base64).filter { $0 != $1 }.count
            #expect(differences == 0, "Native cube \(sample.dimension), \(sample.kind), \(sample.fixture): \(differences) components differ")
        }
    }
}
