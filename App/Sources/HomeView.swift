import SwiftUI
import SleepCore

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var uploader: Uploader

    @State private var alert: AlertMessage?
    @State private var confirmNight = false
    @State private var confirmText = ""
    @State private var sharedFile: SharedFile?
    @State private var preparingExport = false

    var body: some View {
        NavigationStack {
            List {
                if !model.interruptedSessions.isEmpty {
                    interruptedSection
                }
                tonightSection
                testsSection
                sessionsSection
                aboutSection
            }
            .navigationTitle("Sommeil")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { model.refresh() }
            .onAppear { model.refresh() }
        }
        .fullScreenCover(isPresented: Binding(get: { recorder.isRecording }, set: { _ in })) {
            RecordingView()
        }
        .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
        .confirmationDialog("Commencer quand même ?", isPresented: $confirmNight, titleVisibility: .visible) {
            Button("Commencer la nuit") { startNight() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(confirmText)
        }
        .sheet(item: $sharedFile) { ShareSheet(items: [$0.url]) }
    }

    // MARK: - Sections

    private var interruptedSection: some View {
        Section {
            ForEach(model.interruptedSessions, id: \.self) { url in
                if let item = model.sessions.first(where: { $0.url == url }) {
                    NavigationLink { SessionDetailView(item: item) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Enregistrement interrompu").font(.headline)
                                Text(item.summary?.endExplanation ?? item.title).font(.subheadline)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
            }
            Button("J'ai compris") { model.interruptedSessions = [] }
        }
    }

    private var tonightSection: some View {
        Section {
            installationRow
            batteryRow
            if let free = DeviceInfo.freeDiskMB {
                InfoRow(label: "Stockage libre", value: String(format: "%.1f Go", free / 1000),
                        valueColor: free < 2000 ? .red : .primary)
            }
            Button {
                prepareNight()
            } label: {
                Label("Commencer la nuit", systemImage: "moon.zzz.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("Ce soir")
        } footer: {
            Text("Les 30 premières secondes servent de calibration : allongé sur le dos, sans bouger. "
                 + "Ensuite tu peux verrouiller l'écran. " + Texts.charging)
        }
    }

    private var installationRow: some View {
        Group {
            if let expiry = model.installation?.expiration {
                let days = expiry.timeIntervalSinceNow / 86_400
                InfoRow(label: "Installation valable jusqu'au",
                        value: expiry.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()),
                        valueColor: days < 1 ? .red : (days < 2 ? .orange : .primary))
            } else {
                InfoRow(label: "Installation", value: "date d'expiration inconnue")
            }
        }
    }

    private var batteryRow: some View {
        let forecast = model.batteryForecast
        let wake = forecast.wake.formatted(date: .omitted, time: .shortened)
        let level = model.batteryLevel.map { $0.percentText } ?? "?"
        let value: String
        let color: Color
        if let predicted = forecast.predicted {
            value = "\(level) → environ \(max(0, predicted).percentText) à \(wake)"
            switch forecast.verdict {
            case .insuffisant: color = .red
            case .juste: color = .orange
            default: color = .primary
            }
        } else {
            value = "\(level) (consommation pas encore mesurée)"
            color = .primary
        }
        return InfoRow(label: "Batterie", value: value, valueColor: color)
    }

    private var testsSection: some View {
        Section {
            NavigationLink { PlacementView() } label: {
                Label("Test de placement", systemImage: "scope")
            }
            Button {
                recorder.start(kind: .guided) { error in
                    if let error { alert = AlertMessage(title: "Impossible de démarrer", message: error) }
                }
            } label: {
                Label("Test guidé de 10 minutes", systemImage: "list.number")
            }
        } header: {
            Text("Tests")
        } footer: {
            Text("Test guidé : une voix te guide (sur le dos, mouvements, côtés, deux arrêts de respiration de "
                 + "20 secondes). Monte le volume. Si retenir ta respiration est désagréable, respire.")
        }
    }

    private var sessionsSection: some View {
        Section("Enregistrements") {
            if model.sessions.isEmpty {
                Text("Aucun enregistrement pour l'instant.").foregroundStyle(.secondary)
            }
            ForEach(model.sessions) { item in
                NavigationLink { SessionDetailView(item: item) } label: { SessionRow(item: item) }
            }
        }
    }

    private var aboutSection: some View {
        Section {
            Button {
                exportDiagnostic()
            } label: {
                if preparingExport {
                    ProgressView()
                } else {
                    Label("Exporter le journal de diagnostic", systemImage: "doc.text.magnifyingglass")
                }
            }
        } footer: {
            Text(Texts.medical)
        }
    }

    // MARK: - Actions

    private func prepareNight() {
        var warnings: [String] = []
        let forecast = model.batteryForecast
        if forecast.verdict == .insuffisant || forecast.verdict == .juste, let predicted = forecast.predicted {
            warnings.append("La batterie risque d'être presque vide au réveil (environ \(max(0, predicted).percentText)). "
                            + "Charge le téléphone avant de te coucher, jamais attaché sur toi.")
        } else if forecast.predicted == nil, let level = model.batteryLevel, level < 0.5 {
            // Consommation pas encore mesurée : une nuit entière avec moins de la moitié est risquée.
            warnings.append("La batterie n'est qu'à \(level.percentText). Pour une nuit entière, charge le téléphone "
                            + "avant de te coucher, jamais attaché sur toi.")
        }
        if let days = model.installation?.daysRemaining(), days < 0.6 {
            warnings.append("L'installation de l'app expire dans moins de 15 heures. Réinstalle-la avec Sideloadly "
                            + "avant de dormir, sinon l'enregistrement risque de s'arrêter.")
        }
        if let free = DeviceInfo.freeDiskMB, free < 2000 {
            warnings.append("Il reste moins de 2 Go de stockage. Une nuit peut prendre jusqu'à 1 Go.")
        }
        if settings.wantsYeti && settings.pcCode.trimmingCharacters(in: .whitespaces).isEmpty {
            warnings.append("Le code du PC n'est pas renseigné : le Blue Yeti ne démarrera pas. Recopie-le dans "
                            + "Réglages (il s'affiche dans la fenêtre de 5_RECEVOIR_IPHONE.bat).")
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            warnings.append("Le mode économie d'énergie est activé : il peut perturber l'enregistrement.")
        }
        if warnings.isEmpty {
            startNight()
        } else {
            confirmText = warnings.joined(separator: "\n\n")
            confirmNight = true
        }
    }

    private func startNight() {
        recorder.start(kind: .night) { error in
            if let error { alert = AlertMessage(title: "Impossible de démarrer", message: error) }
        }
    }

    private func exportDiagnostic() {
        preparingExport = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SessionStore.makeDiagnosticZip() }
            DispatchQueue.main.async {
                preparingExport = false
                switch result {
                case .success(let url): sharedFile = SharedFile(url: url)
                case .failure(let error):
                    alert = AlertMessage(title: "Export impossible", message: error.localizedDescription)
                }
            }
        }
    }
}

struct SessionRow: View {
    let item: SessionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(item.title).font(.subheadline.weight(.semibold))
                Spacer()
                if item.uploaded {
                    Image(systemName: "checkmark.icloud").foregroundStyle(.green).accessibilityLabel("Envoyé au PC")
                }
            }
            HStack(spacing: 8) {
                Text(item.kindLabel)
                if let summary = item.summary {
                    Text(TimeText.duration(summary.duration))
                    Text("capteurs \(summary.sensorCoverage.percentText)")
                    if !summary.endedNormally {
                        Text("interrompu").foregroundStyle(.orange)
                    }
                } else {
                    Text("en cours ou sans bilan")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
