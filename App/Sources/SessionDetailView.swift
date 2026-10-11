import SwiftUI
import SleepCore

/// Bilan d'une séance : ce qui a été enregistré, ce qui a été perdu et quand, et l'envoi au PC.
struct SessionDetailView: View {
    let item: SessionItem

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var uploader: Uploader
    @Environment(\.dismiss) private var dismiss

    @State private var sizeText = "…"
    @State private var sharedFile: SharedFile?
    @State private var zipping = false
    @State private var confirmDelete = false
    @State private var alert: AlertMessage?

    var body: some View {
        List {
            if let summary = item.summary {
                summarySection(summary)
                lossesSection(summary)
                measuresSection(summary)
            } else {
                Section {
                    Text("Pas encore de bilan pour cette séance (elle est peut-être en cours).")
                }
            }
            sendSection
            Section {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Supprimer de l'iPhone", systemImage: "trash")
                }
            } footer: {
                Text("Supprime seulement la copie de l'iPhone. Vérifie d'abord que la séance est bien arrivée sur le PC.")
            }
        }
        .navigationTitle(item.kindLabel)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let url = item.url
            let bytes = await Task.detached { SessionStore.size(of: url) }.value
            sizeText = String(format: "%.0f Mo", Double(bytes) / 1_000_000)
        }
        .sheet(item: $sharedFile) { ShareSheet(items: [$0.url]) }
        .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
        .confirmationDialog("Supprimer cette séance de l'iPhone ?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                model.delete(item)
                dismiss()
            }
            Button("Annuler", role: .cancel) {}
        }
    }

    private func summarySection(_ summary: SessionSummary) -> some View {
        Section(item.title) {
            Label {
                Text(summary.endExplanation)
            } icon: {
                Image(systemName: summary.endedNormally ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.endedNormally ? .green : .orange)
            }
            InfoRow(label: "Début", value: TimeText.hourMinute(summary.startUnix))
            if let delayed = item.info?.delayedStart {
                InfoRow(label: "Début différé", value: "de \(delayed.delayMinutes) min (« Oui » à \(TimeText.hourMinute(delayed.requestedUnix)))")
            }
            InfoRow(label: "Fin", value: TimeText.hourMinute(summary.endUnix))
            InfoRow(label: "Durée", value: TimeText.duration(summary.duration))
            VStack(alignment: .leading, spacing: 4) {
                InfoRow(label: "Capteurs enregistrés", value: summary.sensorCoverage.percentText)
                QualityBar(value: summary.sensorCoverage, height: 6)
            }
            VStack(alignment: .leading, spacing: 4) {
                InfoRow(label: "Son enregistré", value: summary.audioCoverage.percentText)
                QualityBar(value: summary.audioCoverage, height: 6)
            }
            InfoRow(label: "Interruptions audio", value: "\(summary.interruptions)")
            InfoRow(label: "Taille", value: sizeText)
        }
    }

    @ViewBuilder
    private func lossesSection(_ summary: SessionSummary) -> some View {
        Section("Passages perdus") {
            if summary.losses.isEmpty {
                Text("Aucun : tout a été enregistré.").foregroundStyle(.secondary)
            }
            ForEach(Array(summary.losses.enumerated()), id: \.offset) { _, loss in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(TimeText.hourMinute(loss.startUnix)) — \(TimeText.duration(loss.duration)) sans \(Self.whatText(loss.what))")
                        .font(.subheadline.weight(.semibold))
                    Text(loss.cause).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func measuresSection(_ summary: SessionSummary) -> some View {
        Section("Mesures") {
            ForEach(summary.measuredRates.keys.sorted(), id: \.self) { stream in
                InfoRow(label: "Fréquence réelle · \(RecordingView.streamLabel(stream))",
                        value: String(format: "%.1f Hz", summary.measuredRates[stream] ?? 0))
            }
            if let start = summary.batteryStart, let end = summary.batteryEnd {
                InfoRow(label: "Batterie", value: "\(start.percentText) → \(end.percentText)")
            }
            if let drain = summary.batteryDrainPerHour {
                InfoRow(label: "Consommation", value: String(format: "%.1f %% par heure", drain * 100))
            }
            if let calibration = item.info?.calibration {
                InfoRow(label: "Calibration", value: Self.calibrationText(calibration, mode: item.info?.calibrationMode),
                        valueColor: calibration.isPlausible ? .primary : .orange)
            }
        }
    }

    static func calibrationText(_ calibration: Calibration, mode: String?) -> String {
        let automatic = mode == "automatique"
        if calibration.isPlausible { return automatic ? "automatique, réussie" : "réussie" }
        if calibration.tiltDegrees > Calibration.maxPlausibleTilt {
            return automatic ? "automatique : aucun moment calme sur le dos" : "téléphone incliné (pas sur le dos ?)"
        }
        return automatic ? "automatique : tu bougeais" : "tu as bougé"
    }

    private var sendSection: some View {
        Section {
            let state = uploader.state(for: item.id)
            switch state {
            case .running(let progress, let text):
                ProgressView(value: progress) { Text(text).font(.caption) }
            case .done(let message):
                Label(message, systemImage: "checkmark.circle").foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
            case .idle:
                if item.uploaded { Label("Déjà envoyé au PC", systemImage: "checkmark.icloud") }
            }
            Button {
                guard !settings.pcAddress.isEmpty else {
                    alert = AlertMessage(title: "Adresse du PC manquante",
                                         message: "Lance 5_RECEVOIR_IPHONE.bat sur le PC, puis recopie l'adresse affichée "
                                         + "dans Réglages (roue dentée) › Adresse du PC.")
                    return
                }
                uploader.upload(item.url, address: settings.pcAddress) { model.refresh() }
            } label: {
                Label(item.uploaded ? "Renvoyer au PC" : "Envoyer au PC", systemImage: "arrow.up.circle")
            }
            .disabled({ if case .running = state { return true } else { return false } }())
            Button {
                makeZip()
            } label: {
                if zipping { ProgressView() } else { Label("Partager (fichier .zip)", systemImage: "square.and.arrow.up") }
            }
        } header: {
            Text("Récupérer sur le PC")
        } footer: {
            Text("« Envoyer au PC » passe par le Wi-Fi (garde l'app ouverte pendant l'envoi). En secours, « Partager » "
                 + "permet d'enregistrer un .zip dans Fichiers. Les séances sont aussi visibles dans l'app Fichiers, "
                 + "dans « Sur mon iPhone › Sommeil ».")
        }
    }

    private func makeZip() {
        zipping = true
        let url = item.url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SessionStore.makeZip(of: url) }
            DispatchQueue.main.async {
                zipping = false
                switch result {
                case .success(let zip): sharedFile = SharedFile(url: zip)
                case .failure(let error): alert = AlertMessage(title: "Export impossible", message: error.localizedDescription)
                }
            }
        }
    }

    static func whatText(_ what: String) -> String {
        switch what {
        case "capteurs": return "capteurs"
        case "son": return "son"
        default: return "aucun enregistrement"
        }
    }
}
