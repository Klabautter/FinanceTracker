import SwiftUI

/// WP13: Consumer-tauglicher Icon Picker.
///
/// Kuratierte SF-Symbole mit verständlichen deutschen Labels; Nutzer
/// müssen keine SF-Symbol-Namen kennen. Ein Suchfeld filtert den Katalog.
struct FinanceIconPicker: View {
    @Binding var selection: String

    @State private var query = ""
    @State private var showsCatalog = false
    @State private var popoverAnchor: UUID = UUID()

    /// Kuratierter Katalog (Label deutsch, Keywords für die Suche).
    struct CatalogEntry: Identifiable, Hashable {
        let symbol: String
        let label: String
        let keywords: [String]
        var id: String { symbol }
    }

    static let catalog: [CatalogEntry] = [
        .init(symbol: "cart", label: String(localized: "Einkauf"), keywords: ["supermarkt", "lebensmittel", "shopping"]),
        .init(symbol: "fork.knife", label: String(localized: "Restaurant"), keywords: ["essen", "gastronomie", "café"]),
        .init(symbol: "cup.and.saucer", label: String(localized: "Café"), keywords: ["kaffee", "frühstück"]),
        .init(symbol: "house", label: String(localized: "Wohnen"), keywords: ["miete", "zuhause", "immobilie"]),
        .init(symbol: "car", label: String(localized: "Auto"), keywords: ["fahren", "pkw", "mobilität"]),
        .init(symbol: "fuelpump", label: String(localized: "Tanken"), keywords: ["benzin", "sprit", "treibstoff"]),
        .init(symbol: "bus", label: String(localized: "Bus"), keywords: ["öpnv", "verkehr"]),
        .init(symbol: "tram", label: String(localized: "Bahn"), keywords: ["bahn", "u-bahn", "öpnv"]),
        .init(symbol: "airplane", label: String(localized: "Reisen"), keywords: ["urlaub", "flug", "fernweh"]),
        .init(symbol: "bag", label: String(localized: "Shopping"), keywords: ["kleidung", "mode", "einkaufen"]),
        .init(symbol: "gift", label: String(localized: "Geschenke"), keywords: ["geburtstag", "weihnachten"]),
        .init(symbol: "heart", label: String(localized: "Gesundheit"), keywords: ["apotheke", "arzt", "wellness"]),
        .init(symbol: "cross.case", label: String(localized: "Arzt"), keywords: ["medizin", "behandlung", "gesundheit"]),
        .init(symbol: "graduationcap", label: String(localized: "Bildung"), keywords: ["studium", "schule", "kurs"]),
        .init(symbol: "gamecontroller", label: String(localized: "Games"), keywords: ["spiele", "gaming", "konsolen"]),
        .init(symbol: "tv", label: String(localized: "Streaming"), keywords: ["fernsehen", "abo", "serien"]),
        .init(symbol: "music.note", label: String(localized: "Musik"), keywords: ["spotify", "hören", "abo"]),
        .init(symbol: "bolt", label: String(localized: "Strom"), keywords: ["energie", "elektrizität", "stromrechnung"]),
        .init(symbol: "drop", label: String(localized: "Wasser"), keywords: ["wasserwerk", "gebühren"]),
        .init(symbol: "wifi", label: String(localized: "Internet"), keywords: ["wlan", "provider", "fiber"]),
        .init(symbol: "phone", label: String(localized: "Telefon"), keywords: ["mobilfunk", "vertrag"]),
        .init(symbol: "pawprint", label: String(localized: "Haustier"), keywords: ["hund", "katze", "tierarzt"]),
        .init(symbol: "briefcase", label: String(localized: "Arbeit"), keywords: ["job", "büro", "geschäft"]),
        .init(symbol: "banknote", label: String(localized: "Einnahmen"), keywords: ["gehalt", "einkommen", "gelder"]),
        .init(symbol: "creditcard", label: String(localized: "Karte"), keywords: ["zahlung", "visa", "mastercard"]),
        .init(symbol: "sportscourt", label: String(localized: "Sport"), keywords: ["fitness", "verein", "training"]),
        .init(symbol: "wrench.and.screwdriver", label: String(localized: "Werkstatt"), keywords: ["reparatur", "service", "werkzeug"]),
        .init(symbol: "doc.text", label: String(localized: "Gebühren"), keywords: ["verwaltung", "papierkram", "beiträge"]),
        .init(symbol: "umbrella", label: String(localized: "Versicherung"), keywords: ["schutz", "police"]),
        .init(symbol: "leaf", label: String(localized: "Natur"), keywords: ["garten", "umwelt", "nachhaltig"]),
        .init(symbol: "flame", label: String(localized: "Heizen"), keywords: ["gas", "öl", "wärme"]),
        .init(symbol: "tag", label: String(localized: "Allgemein"), keywords: ["sonstiges", "diverses"])
    ]

    private var filtered: [CatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return Self.catalog }
        return Self.catalog.filter { entry in
            entry.label.lowercased().contains(needle)
                || entry.keywords.contains { $0.contains(needle) }
        }
    }

    private var selectedEntry: CatalogEntry? {
        Self.catalog.first { $0.symbol == selection }
    }

    var body: some View {
        Button {
            showsCatalog = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedEntry?.symbol ?? "tag")
                    .frame(width: 20)
                    .accessibilityHidden(true)
                selectedEntry.map { Text($0.label) } ?? Text("Symbol wählen")
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Symbol wählen: \(selectedEntry?.label ?? String(localized: "kein Symbol"))")
        .popover(isPresented: $showsCatalog, arrowEdge: .bottom) {
            catalogPopover
        }
    }

    private var catalogPopover: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Symbol suchen", text: $query)
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .keyboardType(.alphabet)
                    #endif
                    .accessibilityLabel("Symbole durchsuchen")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Suche zurücksetzen")
                    .help("Suche zurücksetzen")
                }
            }
            .padding(10)

            Divider()

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(filtered) { entry in
                        Button {
                            selection = entry.symbol
                            showsCatalog = false
                            query = ""
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: entry.symbol)
                                    .font(.title3)
                                    .frame(height: 24)
                                Text(entry.label)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(entry.symbol == selection ? Color.accentColor.opacity(0.15) : .clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.symbol == selection ? String(localized: "\(entry.label), ausgewählt") : entry.label)
                    }
                }
                .padding(10)
            }

            if filtered.isEmpty {
                Text("Kein Symbol gefunden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        #if os(macOS)
        .frame(width: 320, height: 340)
        #else
        .frame(maxHeight: 380)
        #endif
    }
}

#if DEBUG
#Preview("Icon Picker") {
    struct PreviewHost: View {
        @State private var icon = "cart"
        var body: some View {
            FinanceIconPicker(selection: $icon)
                .padding()
        }
    }
    return PreviewHost()
}
#endif
