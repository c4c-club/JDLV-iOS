import XCTest
@testable import JDLV

// 设计 token 单测：三套色板 / 6 强调色 / 五级字号行高，数值与 Android 逐项一致。
final class ThemeTokenTests: XCTestCase {
    func testDarkPalette() {
        let p = Theme.dark
        XCTAssertEqual(p.bg0, 0x0F1218)
        XCTAssertEqual(p.bg1, 0x161A22)
        XCTAssertEqual(p.bg2, 0x1C2130)
        XCTAssertEqual(p.bg3, 0x232A38)
        XCTAssertEqual(p.line, 0x2E3648)
        XCTAssertEqual(p.text, 0xE6EAF2)
        XCTAssertEqual(p.text2, 0xA8B0C0)
        XCTAssertEqual(p.accent2, 0x9D8CFF)
        XCTAssertEqual(p.green, 0x5DDC9A)
        XCTAssertEqual(p.red, 0xFF7A8F)
        XCTAssertEqual(p.yellow, 0xFFC861)
    }

    func testLightPalette() {
        let p = Theme.light
        XCTAssertEqual(p.bg0, 0xF2F5FA)
        XCTAssertEqual(p.bg1, 0xFFFFFF)
        XCTAssertEqual(p.bg2, 0xF7F9FC)
        XCTAssertEqual(p.bg3, 0xE7EBF3)
        XCTAssertEqual(p.line, 0xC9D1E0)
        XCTAssertEqual(p.text, 0x1B2030)
        XCTAssertEqual(p.text2, 0x555E73)
        XCTAssertEqual(p.accent2, 0x7C5CFF)
        XCTAssertEqual(p.green, 0x1D9E5F)
        XCTAssertEqual(p.red, 0xD64560)
        XCTAssertEqual(p.yellow, 0xB57D13)
    }

    func testSepiaPalette() {
        let p = Theme.sepia
        XCTAssertEqual(p.bg0, 0xEFE6CF)
        XCTAssertEqual(p.bg1, 0xFBF6E8)
        XCTAssertEqual(p.bg2, 0xF6EFDC)
        XCTAssertEqual(p.bg3, 0xE4D9BC)
        XCTAssertEqual(p.line, 0xCDBB94)
        XCTAssertEqual(p.text, 0x3A3218)
        XCTAssertEqual(p.text2, 0x6A5729)
        XCTAssertEqual(p.accent2, 0xA8791D)
        XCTAssertEqual(p.green, 0x4D7A2A)
        XCTAssertEqual(p.red, 0xB04A3A)
        XCTAssertEqual(p.yellow, 0xA8791D)
    }

    func testAccentsOrderAndFallback() {
        XCTAssertEqual(Theme.accents.map(\.name), ["紫", "蓝", "绿", "橙", "粉", "青"])
        XCTAssertEqual(Theme.accents.map(\.hex), [0x7C5CFF, 0x3D8BFF, 0x2FBF71, 0xFF8C42, 0xFF6B9D, 0x22B8CF])
        XCTAssertEqual(Theme.accentOf("不存在的颜色"), 0x7C5CFF)
        XCTAssertEqual(Theme.accentOf("蓝"), 0x3D8BFF)
    }

    func testPaletteSelection() {
        XCTAssertTrue(Theme.palette(themeName: "dark", systemDark: false).bg0 == Theme.dark.bg0)
        XCTAssertTrue(Theme.palette(themeName: "light", systemDark: true).bg0 == Theme.light.bg0)
        XCTAssertTrue(Theme.palette(themeName: "system", systemDark: true).bg0 == Theme.dark.bg0)
        XCTAssertTrue(Theme.palette(themeName: "system", systemDark: false).bg0 == Theme.light.bg0)
        XCTAssertTrue(Theme.palette(themeName: "sepia", systemDark: true).bg0 == Theme.sepia.bg0)
        XCTAssertTrue(Theme.palette(themeName: "unknown", systemDark: false).bg0 == Theme.dark.bg0)
    }

    func testTypeScale() {
        XCTAssertEqual(Tx.allCases.map(\.size), [20, 16, 15, 13, 12].map(CGFloat.init))
        XCTAssertEqual(Tx.allCases.map(\.lineHeight), [28, 22, 22, 19, 17].map(CGFloat.init))
    }
}
