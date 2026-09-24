import OcteliumCore
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

struct OcteliumColors {
    let app: Color
    let surface: Color
    let surface2: Color
    let surface3: Color
    let line: Color
    let surfaceActive: Color
    let lineStrong: Color
    let strong: Color
    let body: Color
    let muted: Color
    let faint: Color
    let inverse: Color
    let inverseFg: Color
    let inverseHover: Color
    let isDark: Bool

    static let light = OcteliumColors(
        app: Color(hex: 0xF1F5F9),
        surface: Color(hex: 0xFFFFFF),
        surface2: Color(hex: 0xF8FAFC),
        surface3: Color(hex: 0xF1F5F9),
        line: Color(hex: 0xE2E8F0),
        surfaceActive: Color(hex: 0xE2E8F0),
        lineStrong: Color(hex: 0xCBD5E1),
        strong: Color(hex: 0x0F172A),
        body: Color(hex: 0x334155),
        muted: Color(hex: 0x64748B),
        faint: Color(hex: 0x94A3B8),
        inverse: Color(hex: 0x18181B),
        inverseFg: Color(hex: 0xFFFFFF),
        inverseHover: Color(hex: 0x000000),
        isDark: false
    )

    static let dark = OcteliumColors(
        app: Color(hex: 0x0C0C0E),
        surface: Color(hex: 0x171719),
        surface2: Color(hex: 0x1D1D1F),
        surface3: Color(hex: 0x242426),
        line: Color(hex: 0x2C2C2F),
        surfaceActive: Color(hex: 0x2D2D30),
        lineStrong: Color(hex: 0x424245),
        strong: Color(hex: 0xECECEF),
        body: Color(hex: 0xCDCDD1),
        muted: Color(hex: 0xA5A5AA),
        faint: Color(hex: 0x7A7A7F),
        inverse: Color(hex: 0xECECEF),
        inverseFg: Color(hex: 0x161618),
        inverseHover: Color(hex: 0xF8F8FA),
        isDark: true
    )
}

struct ToneColors {
    let background: Color
    let content: Color
    let border: Color
}

enum Palette {
    case slate
    case emerald
    case sky
    case amber
    case rose
    case blue
    case violet
    case indigo
    case cyan
    case teal
    case green
    case fuchsia
    case purple
    case orange

    private var values: (light50: UInt32, light700: UInt32, light200: UInt32, base500: UInt32, dark300: UInt32) {
        switch self {
        case .slate: (0xF1F5F9, 0x334155, 0xE2E8F0, 0x1E293B, 0xCBD5E1)
        case .emerald: (0xECFDF5, 0x047857, 0xA7F3D0, 0x10B981, 0x6EE7B7)
        case .sky: (0xF0F9FF, 0x0369A1, 0xBAE6FD, 0x0EA5E9, 0x7DD3FC)
        case .amber: (0xFFFBEB, 0xB45309, 0xFDE68A, 0xF59E0B, 0xFCD34D)
        case .rose: (0xFFF1F2, 0xBE123C, 0xFECDD3, 0xF43F5E, 0xFDA4AF)
        case .blue: (0xEFF6FF, 0x1D4ED8, 0xBFDBFE, 0x3B82F6, 0x93C5FD)
        case .violet: (0xF5F3FF, 0x6D28D9, 0xDDD6FE, 0x8B5CF6, 0xC4B5FD)
        case .indigo: (0xEEF2FF, 0x4338CA, 0xC7D2FE, 0x6366F1, 0xA5B4FC)
        case .cyan: (0xECFEFF, 0x0E7490, 0xA5F3FC, 0x06B6D4, 0x67E8F9)
        case .teal: (0xF0FDFA, 0x0F766E, 0x99F6E4, 0x14B8A6, 0x5EEAD4)
        case .green: (0xF0FDF4, 0x15803D, 0xBBF7D0, 0x22C55E, 0x86EFAC)
        case .fuchsia: (0xFDF4FF, 0xA21CAF, 0xF5D0FE, 0xD946EF, 0xF0ABFC)
        case .purple: (0xFAF5FF, 0x7E22CE, 0xE9D5FF, 0xA855F7, 0xD8B4FE)
        case .orange: (0xFFF7ED, 0xC2410C, 0xFED7AA, 0xF97316, 0xFDBA74)
        }
    }

    func getColors(_ isDark: Bool) -> ToneColors {
        let v = values

        if !isDark {
            return ToneColors(background: Color(hex: v.light50), content: Color(hex: v.light700), border: Color(hex: v.light200))
        }

        if self == .slate {
            return ToneColors(background: Color(hex: 0x1E293B), content: Color(hex: 0xCBD5E1), border: Color(hex: 0x334155))
        }

        return ToneColors(
            background: Color(hex: v.base500, alpha: 0.1),
            content: Color(hex: v.dark300),
            border: Color(hex: v.base500, alpha: 0.3)
        )
    }
}

func getLabelToneColors(_ tone: LabelTone, _ isDark: Bool) -> ToneColors {
    switch tone {
    case .neutral:
        return isDark
            ? ToneColors(background: Color(hex: 0x1E293B), content: Color(hex: 0xE2E8F0), border: Color(hex: 0x334155))
            : ToneColors(background: Color(hex: 0xF8FAFC), content: Color(hex: 0x334155), border: Color(hex: 0xE2E8F0))
    case .slate:
        return Palette.slate.getColors(isDark)
    case .emerald:
        return Palette.emerald.getColors(isDark)
    case .sky:
        return Palette.sky.getColors(isDark)
    case .amber:
        return Palette.amber.getColors(isDark)
    case .rose:
        return Palette.rose.getColors(isDark)
    }
}

func getConnectivityToneColor(_ tone: ConnectivityTone, _ isDark: Bool) -> Color {
    switch tone {
    case .connected: Color(hex: 0x10B981)
    case .pending: Color(hex: 0xF59E0B)
    case .idle: isDark ? Color(hex: 0x64748B) : Color(hex: 0x94A3B8)
    case .error: Color(hex: 0xF43F5E)
    }
}

enum AlertTone {
    case red
    case blue
    case green
    case orange

    private var values: (base: UInt32, light: UInt32, dark: UInt32) {
        switch self {
        case .red: (0xFA5252, 0xE03131, 0xFF8787)
        case .blue: (0x228BE6, 0x1C7ED6, 0x74C0FC)
        case .green: (0x40C057, 0x2F9E44, 0x8CE99A)
        case .orange: (0xFD7E14, 0xE8590C, 0xFFA94D)
        }
    }

    func getColors(_ isDark: Bool) -> ToneColors {
        let v = values

        return ToneColors(
            background: Color(hex: v.base, alpha: isDark ? 0.15 : 0.1),
            content: Color(hex: isDark ? v.dark : v.light),
            border: Color(hex: v.base, alpha: isDark ? 0.3 : 0.2)
        )
    }
}

let successColor = Color(hex: 0x10B981)

func getDangerColor(_ isDark: Bool) -> Color {
    isDark ? Color(hex: 0xFF6B6B) : Color(hex: 0xFA5252)
}

enum UbuntuWeight {
    case regular
    case medium
    case bold

    var name: String {
        switch self {
        case .regular: "Ubuntu-Regular"
        case .medium: "Ubuntu-Medium"
        case .bold: "Ubuntu-Bold"
        }
    }
}

extension Font {
    static func ubuntu(_ size: CGFloat, _ weight: UbuntuWeight = .medium, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(weight.name, size: size, relativeTo: style)
    }

    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }
}

private struct OcteliumColorsKey: EnvironmentKey {
    static let defaultValue = OcteliumColors.light
}

extension EnvironmentValues {
    var octColors: OcteliumColors {
        get { self[OcteliumColorsKey.self] }
        set { self[OcteliumColorsKey.self] = newValue }
    }
}

struct OcteliumTheme: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let colors = colorScheme == .dark ? OcteliumColors.dark : OcteliumColors.light

        content
            .environment(\.octColors, colors)
            .tint(colors.strong)
    }
}

extension View {
    func octeliumTheme() -> some View {
        modifier(OcteliumTheme())
    }
}

func getColorScheme(_ arg: ThemeMode) -> ColorScheme? {
    switch arg {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
}

func getThemeModeIcon(_ arg: ThemeMode) -> String {
    switch arg {
    case .system: "circle.lefthalf.filled"
    case .light: "sun.max"
    case .dark: "moon"
    }
}
