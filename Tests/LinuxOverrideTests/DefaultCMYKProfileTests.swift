import Foundation
import CoreGraphics
import ColorSync
import Testing
@testable import Compositor

/// The redistributable stand-in for macOS's Generic CMYK (third_party/color): a CMYK output profile the app installs on
/// first run, which upstream then finds and chooses by name, as on a Mac where the user has loaded none.
@MainActor
struct DefaultCMYKProfileTests {
    @Test func bundledProfileIsACMYKOutputProfile() throws {
        let url = try #require(ColorSyncGenericProfiles.bundledDefault, "third_party/color ships the default profile")
        let data = try Data(contentsOf: url)
        let profile = try #require(CMYKProfile(name: "bundled", data: data))
        #expect(profile.space.model == .cmyk)
        // Its own description; only the installed copy is named after Apple's.
        let described = ColorSyncProfileCreate(data, nil).flatMap { ColorSyncProfileCopyDescriptionString($0.takeRetainedValue()) }
        #expect(described?.takeRetainedValue() == "SWOP TR005 Coated" || ColorSyncGenericProfiles.isGenericCMYK(data))
    }

    @Test func installedDefaultIsWhatUpstreamChoosesWithNothingChosen() throws {
        #expect(ColorSyncGenericProfiles.installBundledDefault())
        #expect(FileManager.default.fileExists(atPath: ColorSyncGenericProfiles.genericCMYKFile.path))
        let generic = try #require(CMYK.generic, "upstream finds Generic CMYK by name")
        #expect(generic.space.model == .cmyk)
        // A profile already in place stays: installing again leaves the same bytes.
        let before = try Data(contentsOf: ColorSyncGenericProfiles.genericCMYKFile)
        #expect(ColorSyncGenericProfiles.installBundledDefault())
        #expect(try Data(contentsOf: ColorSyncGenericProfiles.genericCMYKFile) == before)
    }

    @Test func proofAndExportWorkThroughTheDefault() throws {
        #expect(ColorSyncGenericProfiles.installBundledDefault())
        let profile = try #require(CMYK.generic)
        #expect(CMYK.proofLookups(profile) != nil, "View › CMYK › Proof Colors has lookups")
        let context = try #require(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        let image = try #require(context.makeImage())
        let inks = try CMYK.convert(image, to: profile, over: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        #expect(inks.colorSpace?.model == .cmyk)
        let bytes = try #require(inks.dataProvider?.data as Data?)
        // Red prints as magenta and yellow with little cyan.
        #expect(bytes[1] > 200 && bytes[2] > 200 && bytes[0] < 60, "inks \(Array(bytes.prefix(4)))")
    }
}
