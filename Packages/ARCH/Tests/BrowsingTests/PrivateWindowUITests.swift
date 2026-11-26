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
        #expect(reference.backgroundColors == [SpaceTheme.PrivatePalette.backgroundStart.color, SpaceTheme.PrivatePalette.backgroundEnd.color])
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

    @Test func privatePaletteKeepsTextReadableAcrossTheGradientAndControls() {
        typealias Palette = SpaceTheme.PrivatePalette
        #expect(Palette.backgroundStart.luminance > SRGBColor.black.luminance)
        #expect(Palette.backgroundEnd.luminance > SRGBColor.black.luminance)
        #expect(Palette.backgroundStart != Palette.backgroundEnd)
        let gradient = (0...10).map { Palette.backgroundStart.over(Palette.backgroundEnd, opacity: Double($0) / 10) }
        for background in gradient {
            #expect(Palette.field.luminance > background.luminance)
            #expect(Palette.separator.contrast(with: background) >= 3)
        }
        #expect(Palette.selected.luminance > Palette.hover.luminance)
        #expect(Palette.selected.luminance > Palette.field.luminance)
        for background in gradient + [Palette.field, Palette.hover, Palette.selected] {
            #expect(Palette.primary.contrast(with: background) >= SpaceTheme.minimumTextContrast)
            #expect(Palette.secondary.contrast(with: background) >= SpaceTheme.minimumTextContrast)
            #expect(Palette.tertiary.contrast(with: background) >= 3)
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
