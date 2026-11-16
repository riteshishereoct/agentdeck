import AppKit
import SwiftUI
import AgentDeckCore

extension ThemeAccent {
    /// nil = follow the system accent.
    var color: Color? {
        switch self {
        case .system: return nil
        case .ocean: return Color(red: 0.16, green: 0.52, blue: 0.95)
        case .forest: return Color(red: 0.18, green: 0.65, blue: 0.40)
        case .sunset: return Color(red: 0.96, green: 0.52, blue: 0.22)
        case .grape: return Color(red: 0.60, green: 0.38, blue: 0.90)
        case .graphite: return Color(red: 0.45, green: 0.47, blue: 0.52)
        }
    }
    var swatch: Color { color ?? .accentColor }
}

extension ThemeAppearance {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    var colorScheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

private struct DeckSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let settings: AppSettings
    let interactive: Bool

    @ViewBuilder func body(content: Content) -> some View {
        let tint = settings.accent.color ?? .clear
        switch settings.surface {
        case .liquidGlass:
            if #available(macOS 26, *) {
                // Glass already is the transparency control; panelOpacity applies to the fallbacks only.
                if interactive { content.glassEffect(.regular.tint(tint.opacity(0.12)).interactive(), in: shape) }
                else { content.glassEffect(.regular.tint(tint.opacity(0.12)), in: shape) }
            } else {
                content.background(shape.fill(.ultraThinMaterial).opacity(settings.panelOpacity)).overlay(rim)
            }
        case .frosted:
            content.background(shape.fill(.regularMaterial).opacity(settings.panelOpacity)).overlay(rim)
        case .solid:
            content.background(shape.fill(Color(nsColor: .windowBackgroundColor)).opacity(settings.panelOpacity)).overlay(rim)
        }
    }

    private var rim: some View { shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
}

extension View {
    /// Themed floating surface: liquid glass (macOS 26+), frosted material or solid, per AppSettings.
    func deckSurface<S: InsettableShape>(in shape: S, settings: AppSettings, interactive: Bool = false) -> some View {
        modifier(DeckSurface(shape: shape, settings: settings, interactive: interactive))
    }
}
