// Space themes. Each space takes a tint color of its own or Automatic, which follows the accent color chosen in System Settings. The window washes its material with the current space's tint at the strength chosen in Settings ▸ Appearance, resolved in the window's appearance. Where the wash leaves the sidebar's text short of contrast, the sidebar draws its text and icons in the other appearance.
import AppKit
import SwiftUI

extension SpaceTint {
    /// The tints with a color of their own, in the order new spaces take them.
    static let colors = allCases.filter { $0 != .automatic }

    /// The name the space menu shows.
    var title: String { self == .automatic ? "Automatic" : rawValue.capitalized }

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
    /// The sidebar keeps the window's appearance while its text reaches WCAG's 4.5:1 contrast for body text on the wash.
    static let minimumTextContrast = 4.5
    /// Below this contrast against the wash, a space's symbol draws in the sidebar's text color instead of its tint. Several tints miss WCAG's 3:1 for graphics even on the bare light material, so the bar is lower, and only a wash close to the symbol's own color reaches it.
    static let minimumSymbolContrast = 1.5

    /// The current space's tint, resolved so that a change of the system accent color draws the wash anew.
    let tint: Color
    let strength: TintStrength
    /// The appearance the sidebar draws its text and icons in.
    let sidebarColorScheme: ColorScheme
    /// The window's own appearance.
    private let colorScheme: ColorScheme
    /// The wash as the sidebar shows it, at the gradient's average opacity.
    private let wash: SRGBColor

    init(tint: SpaceTint, strength: TintStrength, colorScheme: ColorScheme) {
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

    static let white = SRGBColor(red: 1, green: 1, blue: 1)
    static let black = SRGBColor(red: 0, green: 0, blue: 0)

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// This color drawn at `opacity` over `base`, blended on the sRGB values as the window draws it.
    func over(_ base: SRGBColor, opacity: Double) -> SRGBColor {
        SRGBColor(red: red * opacity + base.red * (1 - opacity), green: green * opacity + base.green * (1 - opacity), blue: blue * opacity + base.blue * (1 - opacity))
    }

    /// Relative luminance as WCAG 2 defines it.
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
        var components = (red: 0.0, green: 0.0, blue: 0.0)
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            if let color = color.usingColorSpace(.sRGB) {
                components = (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
            }
        }
        self.init(red: components.red, green: components.green, blue: components.blue)
    }
}

/// Resolves the theme of the space with `tint` in the window's appearance and passes it to the views inside, again whenever the system colors change: the views hold resolved colors, which do not follow a new accent color by themselves.
struct SpaceThemeModifier: ViewModifier {
    let tint: SpaceTint
    @AppStorage(TintStrength.defaultsKey) private var strength = TintStrength.subtle
    @Environment(\.colorScheme) private var colorScheme
    @State private var systemColorChanges = 0

    func body(content: Content) -> some View {
        // Reading the count makes each change run `body` again, which resolves the accent color anew.
        _ = systemColorChanges
        return content
            .environment(\.spaceTheme, SpaceTheme(tint: tint, strength: strength, colorScheme: colorScheme))
            .onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)) { _ in systemColorChanges += 1 }
    }
}

/// Draws text and icons in the appearance the current space's theme picks for the sidebar.
struct SidebarAppearance: ViewModifier {
    @Environment(\.spaceTheme) private var theme

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, theme.sidebarColorScheme)
    }
}

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
