import SwiftUI
import SleepCore

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var uploader: Uploader

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
            .onAppear {
                model.refresh()
                model.runPendingReminder()
            }
        }
        .fullScreenCover(isPresented: Binding(get: { recorder.isRecording || recorder.isWaiting }, set: { _ in })) {
            RecordingView()
        }
        .alert(item: $model.alert) { Alert(title: Text($0.title), message: Text($0.message)) }
        .sheet(item: $model.startSheet, onDismiss: { model.performQueuedStart() }) { request in
            StartNightSheet(request: request)
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
                model.presentStartSheet()
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
            Text("Tu choisis quand l'enregistrement commence : tout de suite (30 secondes de calibration, "
                 + "allongé sur le dos sans bouger) ou jusqu'à 2 h plus tard (l'app attend en silence). "
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
                    if let error { model.alert = AlertMessage(title: "Impossible de démarrer", message: error) }
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

    private func exportDiagnostic() {
        preparingExport = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SessionStore.makeDiagnosticZip() }
            DispatchQueue.main.async {
                preparingExport = false
                switch result {
                case .success(let url): sharedFile = SharedFile(url: url)
                case .failure(let error):
                    model.alert = AlertMessage(title: "Export impossible", message: error.localizedDescription)
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
