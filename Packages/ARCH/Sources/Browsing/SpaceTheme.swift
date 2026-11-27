// Space themes. Each space takes a tint color of its own or Automatic, which follows the accent color chosen in System Settings. The window washes its material with the current space's tint at the strength chosen in Settings ▸ Appearance, resolved in the window's appearance. Where the wash leaves the sidebar's text short of contrast, the sidebar draws its text and icons in the other appearance.
import AppKit
import SwiftUI

extension SpaceTint {
    /// The tints with a color of their own, in the order new spaces take them.
    static let colors = allCases.filter { $0 != .automatic }

    /// The name the space menu shows.
    var title: String {
        switch self {
        case .automatic: return localized("Automatic")
        case .blue: return localized("Blue")
        case .purple: return localized("Purple")
        case .pink: return localized("Pink")
        case .orange: return localized("Orange")
        case .green: return localized("Green")
        case .teal: return localized("Teal")
        case .gray: return localized("Gray")
        }
    }

    /// A system color that adapts to the appearance it is drawn in.
    var nsColor: NSColor {
        switch self {
        case .automatic: return .controlAccentColor
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .orange: return .systemOrange
        case .green: return .systemGreen
        case .teal: return .systemTeal
        case .gray: return .systemGray
        }
    }

    /// The tint for a theme color read from another browser: gray for a color below 20% saturation, else the tint whose system color in the light appearance has the nearest hue. The components are read as sRGB whatever color space the source names, which moves hue and saturation only a little.
    public static func nearest(red: Double, green: Double, blue: Double) -> SpaceTint {
        let color = hueAndSaturation(red: red, green: green, blue: blue)
        guard color.saturation >= 0.2 else { return .gray }
        // Hues lie on a circle from 0 to 1.
        func distance(to tint: SpaceTint) -> Double {
            let tintColor = SRGBColor(tint.nsColor, in: .light)
            let difference = abs(hueAndSaturation(red: tintColor.red, green: tintColor.green, blue: tintColor.blue).hue - color.hue)
            return min(difference, 1 - difference)
        }
        return colors.filter { $0 != .gray }.min { distance(to: $0) < distance(to: $1) } ?? .gray
    }

    private static func hueAndSaturation(red: Double, green: Double, blue: Double) -> (hue: Double, saturation: Double) {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (Double(hue), Double(saturation))
    }
}

/// How strongly the current space's tint washes the window, saved by its raw value under `ARCHTintStrength`.
public enum TintStrength: String, CaseIterable {
    case subtle
    case medium
    case strong

    public static let defaultsKey = "ARCHTintStrength"

    public var title: String { rawValue.capitalized }

    /// The wash's opacity at the window's top leading and bottom trailing corners.
    var opacities: (start: Double, end: Double) {
        switch self {
        case .subtle: return (0.08, 0.03)
        case .medium: return (0.3, 0.15)
        case .strong: return (0.8, 0.6)
        }
    }
}

/// The current space's tint resolved in the window's appearance. The window passes it to its views in the environment.
struct SpaceTheme: Equatable {
    /// Private-window tint and controls, resolved over the system's dark sidebar material.
    enum PrivatePalette {
        static let backgroundStart = SRGBColor(NSColor(displayP3Red: 0.054, green: 0.060, blue: 0.075, alpha: 1), in: .dark)
        static let backgroundEnd = backgroundStart
        static let field = SRGBColor(red: 1, green: 1, blue: 1, alpha: 0.07)
        static let hover = SRGBColor(NSColor(displayP3Red: 0.98, green: 0.984, blue: 1, alpha: 0.15), in: .dark)
        static let selected = SRGBColor(NSColor(displayP3Red: 0.98, green: 0.984, blue: 1, alpha: 0.2), in: .dark)
        static let primary = SRGBColor(red: 1, green: 1, blue: 1, alpha: 0.8)
        static let secondary = SRGBColor(red: 1, green: 1, blue: 1, alpha: 0.5)
        static let tertiary = SRGBColor(red: 1, green: 1, blue: 1, alpha: 0.3)
        static let separator = SRGBColor(red: 1, green: 1, blue: 1, alpha: 0.15)
        static let buttonHover = Color.white.opacity(0.077)
        static let buttonOn = buttonHover
    }

    /// The sidebar keeps the window's appearance while its text reaches WCAG's 4.5:1 contrast for body text on the wash.
    static let minimumTextContrast = 4.5
    /// Below this contrast against the wash, a space's symbol draws in the sidebar's text color instead of its tint. Several tints miss WCAG's 3:1 for graphics even on the bare light material, so the bar is lower, and only a wash close to the symbol's own color reaches it.
    static let minimumSymbolContrast = 1.5

    /// The current space's tint, resolved so that a change of the system accent color draws the wash anew.
    let tint: Color
    let isPrivate: Bool
    let strength: TintStrength
    /// The appearance the sidebar draws its text and icons in.
    let sidebarColorScheme: ColorScheme
    /// The window's own appearance. What the sidebar opens with a background of its own, such as the site settings popover, draws in it rather than in `sidebarColorScheme`.
    let colorScheme: ColorScheme
    /// The wash as the sidebar shows it, at the gradient's average opacity.
    private let wash: SRGBColor

    init(tint: SpaceTint, strength: TintStrength, colorScheme: ColorScheme, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        if isPrivate {
            self.tint = PrivatePalette.backgroundStart.color
            self.strength = .strong
            self.colorScheme = .dark
            self.wash = PrivatePalette.backgroundStart.over(PrivatePalette.backgroundEnd, opacity: 0.5)
            sidebarColorScheme = .dark
            return
        }
        let tintColor = SRGBColor(tint.nsColor, in: colorScheme)
        // The window background stands in for the sidebar material, whose color depends on what lies behind the window.
        let material = SRGBColor(.windowBackgroundColor, in: colorScheme)
        let wash = tintColor.over(material, opacity: (strength.opacities.start + strength.opacities.end) / 2)
        let windowText = colorScheme == .dark ? SRGBColor.white : .black
        let otherText = colorScheme == .dark ? SRGBColor.black : .white
        let usesOther = wash.contrast(with: windowText) < Self.minimumTextContrast && wash.contrast(with: otherText) > wash.contrast(with: windowText)
        self.tint = tintColor.color
        self.strength = strength
        self.colorScheme = colorScheme
        self.wash = wash
        sidebarColorScheme = usesOther ? (colorScheme == .dark ? .light : .dark) : colorScheme
    }

    /// Both window kinds wash the system material with their tint at the theme's strength.
    var backgroundColors: [Color] {
        [tint.opacity(strength.opacities.start), tint.opacity(strength.opacities.end)]
    }

    /// A space's symbol color: its tint, or the sidebar's text color where the wash comes too close to that tint.
    func symbolColor(for tint: SpaceTint) -> Color {
        let color = SRGBColor(tint.nsColor, in: colorScheme)
        return color.contrast(with: wash) < Self.minimumSymbolContrast ? .primary : color.color
    }
}

/// A color's sRGB components in one appearance, for blending and contrast.
struct SRGBColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let white = SRGBColor(red: 1, green: 1, blue: 1)
    static let black = SRGBColor(red: 0, green: 0, blue: 0)

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    /// This color drawn at `opacity` over `base`, blended on the sRGB values as the window draws it.
    func over(_ base: SRGBColor, opacity: Double) -> SRGBColor {
        let foregroundAlpha = alpha * opacity
        let backgroundAlpha = base.alpha * (1 - foregroundAlpha)
        let resultAlpha = foregroundAlpha + backgroundAlpha
        guard resultAlpha > 0 else { return SRGBColor(red: 0, green: 0, blue: 0, alpha: 0) }
        return SRGBColor(red: (red * foregroundAlpha + base.red * backgroundAlpha) / resultAlpha, green: (green * foregroundAlpha + base.green * backgroundAlpha) / resultAlpha, blue: (blue * foregroundAlpha + base.blue * backgroundAlpha) / resultAlpha, alpha: resultAlpha)
    }

    /// Relative luminance of the RGB components. Composite translucent colors over their background before comparing contrast.
    var luminance: Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG 2 contrast ratio, from 1 to 21.
    func contrast(with other: SRGBColor) -> Double {
        (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
    }
}

extension SRGBColor {
    /// Resolves a dynamic system color as the light or dark appearance draws it.
    init(_ color: NSColor, in scheme: ColorScheme) {
        var components = (red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            if let color = color.usingColorSpace(.sRGB) {
                components = (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent), Double(color.alphaComponent))
            }
        }
        self.init(red: components.red, green: components.green, blue: components.blue, alpha: components.alpha)
    }
}

/// Resolves the theme of the space with `tint` in the window's appearance and passes it to the views inside, again whenever the system colors change: the views hold resolved colors, which do not follow a new accent color by themselves.
struct SpaceThemeModifier: ViewModifier {
    let tint: SpaceTint
    var isPrivate = false
    @AppStorage(TintStrength.defaultsKey) private var strength = TintStrength.subtle
    @Environment(\.colorScheme) private var colorScheme
    @State private var systemColorChanges = 0

    func body(content: Content) -> some View {
        // Reading the count makes each change run `body` again, which resolves the accent color anew.
        _ = systemColorChanges
        return content
            .environment(\.spaceTheme, SpaceTheme(tint: tint, strength: strength, colorScheme: colorScheme, isPrivate: isPrivate))
            .onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)) { _ in systemColorChanges += 1 }
    }
}

/// Draws text and icons in the appearance the current space's theme picks for the sidebar.
struct SidebarAppearance: ViewModifier {
    @Environment(\.spaceTheme) private var theme

    func body(content: Content) -> some View {
        if theme.isPrivate {
            content
                .foregroundStyle(SpaceTheme.PrivatePalette.primary.color, SpaceTheme.PrivatePalette.secondary.color, SpaceTheme.PrivatePalette.tertiary.color)
                .environment(\.colorScheme, theme.sidebarColorScheme)
        } else {
            content.environment(\.colorScheme, theme.sidebarColorScheme)
        }
    }
}

/// The environment key behind `spaceTheme`.
private struct SpaceThemeKey: EnvironmentKey {
    static let defaultValue = SpaceTheme(tint: .blue, strength: .subtle, colorScheme: .light)
}

extension EnvironmentValues {
    /// The current space's theme, set at the window's root.
    var spaceTheme: SpaceTheme {
        get { self[SpaceThemeKey.self] }
        set { self[SpaceThemeKey.self] = newValue }
    }
}
