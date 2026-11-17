import Foundation
import Testing

@testable import FinanceTracker

/// Roadmap 6.2: Signalfarben, die als Text stehen (Beträge in Grün und Rot,
/// Hinweise in Orange und Blau), müssen auf jeder Fläche der App lesbar
/// sein. Geprüft wird nach WCAG 2.1 AA.
@Suite("PaletteContrast")
struct PaletteContrastTests {
    @Test("Kontrastformel: Schwarz auf Weiß 21 : 1, gleiche Farbe 1 : 1")
    func formula() {
        #expect(abs(AppPaletteValues.contrast(0x000000, 0xFFFFFF) - 21) < 0.001)
        #expect(AppPaletteValues.contrast(0x777777, 0x777777) == 1)
        // Bekannter Referenzwert: #767676 auf Weiß ist die AA-Grenze.
        #expect(abs(AppPaletteValues.contrast(0x767676, 0xFFFFFF) - 4.54) < 0.01)
    }

    @Test("Textfarben halten AA (4,5 : 1) auf jeder Fläche, hell und dunkel")
    func textColorsMeetAA() {
        for color in AppPaletteValues.textColors {
            for surface in AppPaletteValues.surfaces {
                let light = AppPaletteValues.contrast(color.value.light, surface.value.light)
                let dark = AppPaletteValues.contrast(color.value.dark, surface.value.dark)
                #expect(light >= 4.5, "\(color.name) auf \(surface.name) (hell): \(light)")
                #expect(dark >= 4.5, "\(color.name) auf \(surface.name) (dunkel): \(dark)")
            }
        }
    }

    @Test("Prognoselinie im Diagramm hält 3 : 1 auf Karte und Arbeitsfläche")
    func chartLineMeetsGraphicsContrast() {
        let line = AppPaletteValues.chartForecast
        for surface in [AppPaletteValues.card, AppPaletteValues.canvas] {
            #expect(AppPaletteValues.contrast(line.light, surface.light) >= 3)
            #expect(AppPaletteValues.contrast(line.dark, surface.dark) >= 3)
        }
    }
}
