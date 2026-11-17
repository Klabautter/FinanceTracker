import SwiftUI

/// Wofür ein Passwort gebraucht wird: ein neues Backup schützen oder ein
/// geschütztes öffnen. Ein Enum für EIN item-basiertes Sheet (mehrere
/// `sheet(isPresented:)` am selben View erzeugen auf macOS leere Sheets).
enum BackupPasswordRequest: Identifiable, Equatable {
    case export
    case restore(fileName: String)

    var id: String {
        switch self {
        case .export: "export"
        case .restore(let fileName): "restore-\(fileName)"
        }
    }
}

/// Passwort für ein Backup festlegen oder eingeben. Das Passwort bleibt in
/// diesem Dialog und wird nirgends gespeichert.
struct BackupPasswordSheet: View {
    let request: BackupPasswordRequest
    /// Fehler vom Öffnen (falsches Passwort).
    let errorMessage: String?
    let onExport: (_ password: String, _ includeAttachments: Bool) async -> Void
    let onUnlock: (_ password: String) async -> Void

    @State private var password = ""
    @State private var repeated = ""
    @State private var includeAttachments = true
    @State private var isWorking = false
    @Environment(\.dismiss) private var dismiss

    private var isExport: Bool { request == .export }

    /// Beim Festlegen: Mindestlänge und gleiche Wiederholung.
    private var problem: String? {
        isExport ? SettingsModel.backupPasswordProblem(password, repeated: repeated) : nil
    }

    private var canConfirm: Bool {
        !isWorking && !password.isEmpty && problem == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            Label(title, systemImage: isExport ? "lock" : "lock.open")
                .font(.headline)
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Passwort", text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("backup-password")
                .onSubmit { if !isExport { confirm() } }
            if isExport {
                SecureField("Passwort wiederholen", text: $repeated)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("backup-password-repeat")
                    .onSubmit { confirm() }
                Toggle("Belege einschließen", isOn: $includeAttachments)
            }

            if let message = visibleMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(AppPalette.critical)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("backup-password-error")
            }

            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text(isExport ? "Backup wird verschlüsselt…" : "Backup wird geöffnet…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button(isExport ? "Backup erstellen" : "Öffnen") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
                    .accessibilityIdentifier("backup-password-confirm")
            }
        }
        .padding(AppSpacing.l)
        #if os(macOS)
        .frame(width: 420)
        #endif
        .interactiveDismissDisabled(isWorking)
    }

    private var title: String {
        switch request {
        case .export: String(localized: "Backup mit Passwort schützen")
        case .restore(let fileName): String(localized: "Passwort für „\(fileName)“")
        }
    }

    private var explanation: String {
        isExport
            ? String(localized: "Das Backup wird mit diesem Passwort verschlüsselt. Ohne das Passwort lässt es sich nicht wiederherstellen; die App speichert es nirgends und kann es nicht zurücksetzen.")
            : String(localized: "Dieses Backup ist mit einem Passwort geschützt.")
    }

    /// Erst ab der ersten Wiederholung meckern, nicht beim ersten Zeichen.
    private var visibleMessage: String? {
        if isExport {
            return repeated.isEmpty ? nil : problem
        }
        return errorMessage
    }

    private func confirm() {
        guard canConfirm else { return }
        isWorking = true
        Task {
            if isExport {
                await onExport(password, includeAttachments)
            } else {
                await onUnlock(password)
            }
            isWorking = false
        }
    }
}
