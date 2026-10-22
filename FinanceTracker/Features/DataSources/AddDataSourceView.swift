import SwiftUI

enum AddDataSourceRoute: Hashable {
    case bank
    case fileImport
}

struct AddDataSourceView: View {
    let dependencies: AppDependencies
    let onDismiss: () -> Void
    /// Optional: Konto manuell anlegen (Bargeld, Konto ohne Anbindung).
    /// Der Aufrufer öffnet den Editor und schließt diesen Dialog.
    var onManualAccount: (() -> Void)? = nil

    @State private var path: [AddDataSourceRoute] = []
    /// Ohne Callback des Aufrufers öffnet der Dialog den Konto-Editor selbst,
    /// so gibt es „Konto manuell anlegen“ von überall (Übersicht,
    /// Transaktionen, Sammlungen), nicht nur unter Konten.
    @State private var showsAccountEditor = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    PageHeader(String(localized: "Daten hinzufügen"), subtitle: String(localized: "Verbinde deine Bank oder importiere einen Export."))
                    Button {
                        path.append(.bank)
                    } label: {
                        sourceRow(title: "Bankkonto verbinden", subtitle: "Konten und Transaktionen synchronisieren", systemImage: "building.columns")
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    Button {
                        path.append(.fileImport)
                    } label: {
                        sourceRow(title: "Datei importieren", subtitle: "CSV, Excel oder PDF-Kontoauszug von Bank, Karte oder Broker", systemImage: "doc.badge.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    do {
                        Button {
                            if let onManualAccount {
                                onManualAccount()
                            } else {
                                showsAccountEditor = true
                            }
                        } label: {
                            sourceRow(title: "Konto manuell anlegen", subtitle: "Bargeld, Geldbeutel oder ein Konto ohne Anbindung, mit Anfangsbestand. Buchungen trägst du selbst ein", systemImage: "wallet.pass")
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                    }
                    Label("Bankzugriff nur zum Lesen. Du behältst die Kontrolle über deine Daten.", systemImage: "lock.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AppSpacing.xl)
            }
            .workspaceCanvas()
            // macOS zeigt den Stack-Titel als zweite Überschrift direkt über
            // dem Seitenkopf „Daten hinzufügen": dort bleibt er leer.
            #if os(iOS)
            .navigationTitle("Datenquelle hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            #else
            .navigationTitle("")
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { onDismiss() }
                }
            }
            .sheet(isPresented: $showsAccountEditor) {
                AccountEditorSheet(
                    dependencies: dependencies,
                    editing: nil,
                    transactionCount: 0,
                    onSaved: { onDismiss() }
                )
            }
            .navigationDestination(for: AddDataSourceRoute.self) { route in
                switch route {
                case .bank:
                    BankConnectView(dependencies: dependencies, onDone: { onDismiss() })
                        .toolbar {
                            ToolbarItem(placement: .navigation) {
                                Button("Zurück") { path.removeLast() }
                            }
                        }
                case .fileImport:
                    ImportView(dependencies: dependencies)
                        .toolbar {
                            ToolbarItem(placement: .navigation) {
                                Button("Zurück") { path.removeLast() }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Fertig") { onDismiss() }
                            }
                        }
                }
            }
        }
    }

    private func sourceRow(title: LocalizedStringKey, subtitle: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: AppSpacing.m) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: AppRadius.medium))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(title)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(AppSpacing.xl)
        .appSurface(.groupedContent)
        .contentShape(Rectangle())
    }
}
