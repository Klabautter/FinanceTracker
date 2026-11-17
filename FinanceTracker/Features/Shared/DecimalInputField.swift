import SwiftUI

/// WP4 (§29): Wiederverwendbares Decimal-Eingabefeld.
///
/// Trennt Display-Formatierung von Edit-Input: das Feld führt einen
/// reinen Zahlen-String (kein Währungssymbol im editierbaren Wert) und
/// schreibt geparste Werte in ein typed `Decimal?`-Binding. Unparsebare
/// Eingaben werden als sichtbarer Validierungsfehler angezeigt, niemals
/// still ignoriert (§38).
struct DecimalInputField: View {

    let title: String
    @Binding var value: Decimal?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $text)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .onChange(of: text) { _, newValue in
                    syncValue(from: newValue)
                }
                .onChange(of: value) { _, newValue in
                    syncText(from: newValue)
                }

            if isInvalid {
                Label("Bitte einen gültigen Betrag eingeben.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AppPalette.critical)
            } else {
                DecimalInputEcho(text: text)
            }
        }
    }

    @State private var text: String = ""
    @State private var isInvalid = false

    /// Initialisiert das Feld mit dem Rohwert (ohne Währungssymbol).
    init(title: String, value: Binding<Decimal?>) {
        self.title = title
        _value = value
        if let initial = value.wrappedValue {
            _text = State(initialValue: Self.editText(initial))
        }
    }

    private func syncValue(from newValue: String) {
        guard !newValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            value = nil
            isInvalid = false
            return
        }
        if let parsed = Self.parse(newValue) {
            value = parsed
            isInvalid = false
        } else {
            // §38: Invalid → Save blockieren (value = nil) und sichtbaren
            // Fehler zeigen. Kein stiller Fallback auf den alten Wert.
            value = nil
            isInvalid = true
        }
    }

    /// Externe Wert-Änderungen (z. B. Load im Sheet `.task`) ziehen den
    /// Text nach, aber nur, wenn der Text den Wert nicht bereits
    /// repräsentiert (kein Cursor-Sprung während der Eingabe).
    private func syncText(from newValue: Decimal?) {
        if let newValue {
            if Self.parse(text) != newValue {
                text = Self.editText(newValue)
            }
            isInvalid = false
        } else if Self.parse(text) != nil {
            text = ""
            isInvalid = false
        }
    }

    /// Dezimaltrenner der Systemsprache: „1.500" ist auf Deutsch 1500.
    nonisolated static func parse(_ text: String, locale: Locale = .current) -> Decimal? {
        DecimalParser.parse(text, decimalSeparator: locale.decimalSeparator?.first)
    }

    /// Bearbeitbarer Text im Format der Systemsprache, ohne Tausenderpunkte.
    nonisolated static func editText(_ value: Decimal, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(0...2)))
    }

    nonisolated static func display(_ value: Decimal, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale).precision(.fractionLength(2)))
    }

    /// Nur bei Trennzeichen lohnt der Hinweis; „500" versteht jeder.
    nonisolated static func needsEcho(_ text: String) -> Bool {
        text.contains(",") || text.contains(".")
    }
}

/// Zeigt unter einem freien Betragsfeld, wie die Eingabe verstanden wurde
/// („1.500" → „= 1.500,00"). Für Felder, die ihren Text selbst halten
/// (neue Buchung, Split, Gruppenanteil) und deshalb nicht
/// `DecimalInputField` verwenden.
struct DecimalInputEcho: View {
    let text: String
    var locale: Locale = .current

    var body: some View {
        if DecimalInputField.needsEcho(text), let value = DecimalInputField.parse(text, locale: locale) {
            let shown = DecimalInputField.display(value, locale: locale)
            Text("= \(shown)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Verstanden als \(shown)"))
        }
    }
}
