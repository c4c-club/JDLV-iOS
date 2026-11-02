import SwiftUI

// 主题 token 体系，数值与 Android theme/Theme.kt、theme/Type.kt 逐项一致。
// 色板：深色 #0F1218 系 / 浅色 #F2F5FA 系 / 护眼 #EFE6CF 系。

public extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: Double((hex >> 24) & 0xFF) / 255.0
        )
    }
}

public struct PalTokens: Equatable {
    public let bg0: UInt32   // 页面背景
    public let bg1: UInt32   // 卡片 surface
    public let bg2: UInt32   // 高一层容器
    public let bg3: UInt32   // surfaceVariant (chips/输入框底)
    public let line: UInt32  // 描边
    public let text: UInt32  // 主文本
    public let text2: UInt32 // 次级文本
    public let accent2: UInt32
    public let green: UInt32
    public let red: UInt32
    public let yellow: UInt32

    public init(bg0: UInt32, bg1: UInt32, bg2: UInt32, bg3: UInt32, line: UInt32,
                text: UInt32, text2: UInt32, accent2: UInt32, green: UInt32,
                red: UInt32, yellow: UInt32) {
        self.bg0 = bg0; self.bg1 = bg1; self.bg2 = bg2; self.bg3 = bg3
        self.line = line; self.text = text; self.text2 = text2
        self.accent2 = accent2; self.green = green; self.red = red; self.yellow = yellow
    }
}

public enum Theme {
    public static let dark = PalTokens(
        bg0: 0x0F1218, bg1: 0x161A22, bg2: 0x1C2130, bg3: 0x232A38, line: 0x2E3648,
        text: 0xE6EAF2, text2: 0xA8B0C0, accent2: 0x9D8CFF, green: 0x5DDC9A,
        red: 0xFF7A8F, yellow: 0xFFC861)

    public static let light = PalTokens(
        bg0: 0xF2F5FA, bg1: 0xFFFFFF, bg2: 0xF7F9FC, bg3: 0xE7EBF3, line: 0xC9D1E0,
        text: 0x1B2030, text2: 0x555E73, accent2: 0x7C5CFF, green: 0x1D9E5F,
        red: 0xD64560, yellow: 0xB57D13)

    public static let sepia = PalTokens(
        bg0: 0xEFE6CF, bg1: 0xFBF6E8, bg2: 0xF6EFDC, bg3: 0xE4D9BC, line: 0xCDBB94,
        text: 0x3A3218, text2: 0x6A5729, accent2: 0xA8791D, green: 0x4D7A2A,
        red: 0xB04A3A, yellow: 0xA8791D)

    // 6 个强调色，顺序即 UI 顺序（Android ACCENTS LinkedHashMap）
    public static let accents: [(name: String, hex: UInt32)] = [
        ("紫", 0x7C5CFF), ("蓝", 0x3D8BFF), ("绿", 0x2FBF71),
        ("橙", 0xFF8C42), ("粉", 0xFF6B9D), ("青", 0x22B8CF),
    ]

    public static func accentOf(_ name: String) -> UInt32 {
        accents.first { $0.name == name }?.hex ?? 0x7C5CFF
    }

    // theme_name: system/dark/light/sepia；护眼仅浅色系下生效（深色系统回落 DARK）
    public static func palette(themeName: String, systemDark: Bool) -> PalTokens {
        switch themeName {
        case "light": return light
        case "sepia": return sepia
        case "system": return systemDark ? dark : light
        default: return dark
        }
    }
}

// 五级字号/行高（20/16/15/13/12 + 28/22/22/19/17），最小 12pt
public enum Tx: CaseIterable {
    case titleL, titleM, body, bodyS, meta

    public var size: CGFloat {
        switch self {
        case .titleL: return 20
        case .titleM: return 16
        case .body: return 15
        case .bodyS: return 13
        case .meta: return 12
        }
    }

    public var lineHeight: CGFloat {
        switch self {
        case .titleL: return 28
        case .titleM: return 22
        case .body: return 22
        case .bodyS: return 19
        case .meta: return 17
        }
    }

    public var weight: Font.Weight {
        switch self {
        case .titleL: return .bold
        case .titleM: return .semibold
        default: return .regular
        }
    }
}

// 解析后的运行时主题（App 层注入 environment）
public struct AppTheme {
    public let pal: PalTokens
    public let accentHex: UInt32

    public var accent: Color { Color(hex: accentHex) }
    public var bg0: Color { Color(hex: pal.bg0) }
    public var bg1: Color { Color(hex: pal.bg1) }
    public var bg2: Color { Color(hex: pal.bg2) }
    public var bg3: Color { Color(hex: pal.bg3) }
    public var line: Color { Color(hex: pal.line) }
    public var text: Color { Color(hex: pal.text) }
    public var text2: Color { Color(hex: pal.text2) }
    public var green: Color { Color(hex: pal.green) }
    public var red: Color { Color(hex: pal.red) }
    public var yellow: Color { Color(hex: pal.yellow) }

    public init(pal: PalTokens, accentHex: UInt32) {
        self.pal = pal
        self.accentHex = accentHex
    }

    // 无设置兜底：DARK 色板 + 紫（与 Android fallbackTheme 一致）
    public static func fallback() -> AppTheme {
        AppTheme(pal: Theme.dark, accentHex: Theme.accentOf("紫"))
    }
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.fallback()
}

public extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}
