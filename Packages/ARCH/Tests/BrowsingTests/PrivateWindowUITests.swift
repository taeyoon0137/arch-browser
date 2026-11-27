// Private window commands and appearance are checked without creating or showing a window.
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Browsing

@MainActor
@Suite struct PrivateWindowUITests {
    @Test func fileCommandUsesCommandShiftNAndTheRequestedTarget() {
        let target = PrivateWindowCommandTarget()
        let action = #selector(PrivateWindowCommandTarget.openPrivateWindow)
        let item = PrivateWindowCommand.menuItem(target: target, action: action)
        #expect(item.keyEquivalent.lowercased() == "n")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
        #expect(item.action == action)
        #expect(item.target === target)
        _ = target.perform(action)
        #expect(target.openCount == 1)
    }

    @Test func dockCommandUsesTheSameActionWithoutAShortcut() {
        let target = PrivateWindowCommandTarget()
        let action = #selector(PrivateWindowCommandTarget.openPrivateWindow)
        let file = PrivateWindowCommand.menuItem(target: target, action: action)
        let dock = PrivateWindowCommand.menuItem(target: target, action: action, withShortcut: false)
        #expect(dock.title == file.title)
        #expect(dock.action == file.action)
        #expect(dock.keyEquivalent.isEmpty)
        #expect(dock.keyEquivalentModifierMask.isEmpty)
    }

    @Test func privateThemeIsIndependentOfSpaceAndSystemAppearance() {
        let reference = SpaceTheme(tint: .gray, strength: .subtle, colorScheme: .dark, isPrivate: true)
        // The private tint washes the dark material at the strong strength, as an ordinary window's tint does.
        let opacities = TintStrength.strong.opacities
        #expect(reference.backgroundColors == [SpaceTheme.PrivatePalette.backgroundStart.color.opacity(opacities.start),
                                               SpaceTheme.PrivatePalette.backgroundStart.color.opacity(opacities.end)])
        for tint in SpaceTint.allCases {
            for strength in TintStrength.allCases {
                for scheme in [ColorScheme.light, .dark] {
                    let theme = SpaceTheme(tint: tint, strength: strength, colorScheme: scheme, isPrivate: true)
                    #expect(theme == reference)
                    #expect(theme.isPrivate)
                    #expect(theme.backgroundColors == reference.backgroundColors)
                    #expect(theme.colorScheme == .dark)
                    #expect(theme.sidebarColorScheme == .dark)
                }
            }
        }
    }

    @Test func privatePaletteKeepsTextReadableOnItsBackgroundAndControls() {
        typealias Palette = SpaceTheme.PrivatePalette
        // One solid background; the controls and text are translucent white, so each is composited over what it sits on.
        let background = Palette.backgroundStart
        #expect(Palette.backgroundEnd == background)
        #expect(background.luminance > SRGBColor.black.luminance)
        let field = Palette.field.over(background, opacity: 1)
        let hover = Palette.hover.over(background, opacity: 1)
        let selected = Palette.selected.over(background, opacity: 1)
        #expect(Palette.separator.over(background, opacity: 1).luminance > background.luminance)
        #expect(field.luminance > background.luminance)
        #expect(selected.luminance > hover.luminance)
        #expect(selected.luminance > field.luminance)
        for surface in [background, field, hover, selected] {
            #expect(Palette.primary.over(surface, opacity: 1).contrast(with: surface) >= SpaceTheme.minimumTextContrast)
            #expect(Palette.tertiary.over(surface, opacity: 1).contrast(with: surface) >= 2)
        }
        // Secondary text reaches body-text contrast on the sidebar's background; on a highlighted row it still stays at least 3:1.
        #expect(Palette.secondary.over(background, opacity: 1).contrast(with: background) >= SpaceTheme.minimumTextContrast)
        for surface in [field, hover, selected] {
            #expect(Palette.secondary.over(surface, opacity: 1).contrast(with: surface) >= 3)
        }
    }

    @Test func appMenusRouteToThePrivateWindowCommandAndKoreanIsAvailable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Packages/ARCHApp/Sources/Arch/AppDelegate.swift"), encoding: .utf8)
        #expect(app.contains("fileMenu.addItem(PrivateWindowCommand.menuItem(target: self, action: #selector(newPrivateWindow)))"))
        #expect(app.contains("menu.addItem(PrivateWindowCommand.menuItem(target: self, action: #selector(newPrivateWindow), withShortcut: false))"))
        #expect(app.contains("@objc private func newPrivateWindow() { session.openPrivateWindow().showCommandPalette(.newTab) }"))
        #expect(app.contains("if let active = session.activeWindow, active.isPrivate { return active }"))
        #expect(app.contains("@objc private func newTab() { frontSidebarTarget().showCommandPalette(.newTab) }"))
        #expect(app.contains("!session.windows.contains(where: { $0.kind == .main })"))
        let data = try Data(contentsOf: root.appendingPathComponent("Packages/ARCH/Sources/Browsing/Resources/Localizable.xcstrings"))
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let entry = try #require(strings["New Private Window"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let korean = try #require(localizations["ko"] as? [String: Any])
        let unit = try #require(korean["stringUnit"] as? [String: String])
        #expect(unit["value"] == "새 개인정보 보호 창")
    }
}

@MainActor
private final class PrivateWindowCommandTarget: NSObject {
    var openCount = 0
    @objc func openPrivateWindow() { openCount += 1 }
}
