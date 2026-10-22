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
            _text = State(initialValue: "\(initial)")
        }
    }

    private func syncValue(from newValue: String) {
        guard !newValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            value = nil
            isInvalid = false
            return
        }
        if let parsed = DecimalParser.parse(newValue) {
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
            if DecimalParser.parse(text) != newValue {
                text = "\(newValue)"
            }
            isInvalid = false
        } else if DecimalParser.parse(text) != nil {
            text = ""
            isInvalid = false
        }
    }
}