import SwiftUI
import SleepCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: Recorder

    @State private var notificationsDenied = false
    @State private var reminderTestSent = false
    @State private var sharedFile: SharedFile?
    @State private var preparingExport = false
    @State private var showRenewal = false

    var body: some View {
        NavigationStack {
            Form {
                reminderSection
                recordingSection
                installationSection
                diagnosticSection
                Section {
                    Text(Texts.medical).font(.footnote)
                    Text(Texts.charging).font(.footnote)
                }
            }
            .navigationTitle("Réglages")
            .onAppear {
                NightReminder.shared.isDenied { notificationsDenied = $0 }
            }
            .onChange(of: settings.bedtimeReminder) { _, enabled in
                guard enabled else { return model.updateReminders() }
                NightReminder.shared.requestAuthorization { granted in
                    notificationsDenied = !granted
                    model.updateReminders()
                }
            }
            .onChange(of: settings.bedtimeMinutes) { _, _ in
                model.updateReminders()
            }
            .sheet(item: $sharedFile) { ShareSheet(items: [$0.url]) }
            .sheet(isPresented: $showRenewal) { RenewalSheet() }
        }
    }

    private var reminderSection: some View {
        Section {
            Toggle(isOn: $settings.bedtimeReminder.animation(.snappy)) {
                Label("Me proposer de démarrer la nuit", systemImage: "bell.badge.fill")
            }
            if settings.bedtimeReminder {
                DatePicker("Heure du rappel", selection: Binding(get: { settings.bedtimeDate },
                                                                set: { settings.bedtimeDate = $0 }),
                           displayedComponents: .hourAndMinute)
                Button(reminderTestSent ? "Notification envoyée : verrouille l'écran (5 s)" : "Essayer la notification") {
                    NightReminder.shared.sendTest(defaultDelay: settings.lastDelayMinutes)
                    reminderTestSent = true
                }
                .disabled(notificationsDenied)
            }
            if notificationsDenied {
                Text("Les notifications de Sommeil sont refusées : Réglages de l'iPhone › Notifications › "
                     + "Sommeil › Autoriser les notifications.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Rappel du soir")
        } footer: {
            Text("Chaque soir à cette heure, une notification « Démarrer la nuit ? ». Appuie longuement dessus : "
                 + "une barre permet de choisir quand l'enregistrement commence (tout de suite ou jusqu'à 2 h plus "
                 + "tard). « Oui » ouvre l'app un instant : iOS l'exige pour allumer le micro. Si tu utilises le "
                 + "mode de concentration Sommeil, ajoute l'app Sommeil à ses apps autorisées.")
        }
    }

    @ViewBuilder
    private var recordingSection: some View {
        Section {
            DatePicker(selection: Binding(get: { settings.wakeDate }, set: { settings.wakeDate = $0 }),
                       displayedComponents: .hourAndMinute) {
                Label("Heure du réveil", systemImage: "alarm")
            }
            Toggle(isOn: $settings.voicePrompts) {
                Label("Consignes à voix haute", systemImage: "speaker.wave.2.fill")
            }
            Toggle(isOn: $settings.rawSensors) {
                Label("Capteurs bruts en plus", systemImage: "cpu")
            }
        } header: {
            Text("Enregistrement")
        } footer: {
            Text("L'heure du réveil sert à prévoir la batterie restante le matin. « Capteurs bruts » enregistre aussi "
                 + "l'accéléromètre et le gyroscope non traités par iOS : utile pour affiner l'analyse, un peu plus "
                 + "de batterie et de stockage.")
        }
        Section {
            Toggle(isOn: $settings.mediaFriendlyAudio) {
                Label("Vidéo ou podcast en m'endormant", systemImage: "play.tv.fill")
            }
            .disabled(recorder.isRecording || recorder.isWaiting)
        } header: {
            Text("Micro")
        } footer: {
            Text("Activé : une vidéo ou un podcast garde un son normal pendant que l'app écoute (le micro passe en "
                 + "réglage « normal » d'iOS). Désactivé : son brut, le plus fidèle pour l'analyse, mais le son des "
                 + "autres apps devient faible et métallique sur le haut-parleur. Dans les deux cas, des écouteurs "
                 + "Bluetooth restent en bonne qualité, et le son de la vidéo s'entend aussi sur l'enregistrement. "
                 + "Le réglage s'applique à la prochaine nuit.")
        }
    }

    private var installationSection: some View {
        Section {
            if let info = model.installation, let expiry = info.expiration {
                let days = expiry.timeIntervalSinceNow / 86_400
                InfoRow(label: "Valable jusqu'au",
                        value: expiry.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()),
                        valueColor: days < 1 ? .red : (days < 2 ? .orange : .primary))
                if let team = info.teamName { InfoRow(label: "Signée par", value: team) }
            } else {
                Text("Profil d'installation introuvable.").foregroundStyle(.secondary)
            }
            Button {
                showRenewal = true
            } label: {
                Label("Renouveler avec SideStore", systemImage: "arrow.triangle.2.circlepath")
            }
            InfoRow(label: "Version de l'app", value: DeviceInfo.appVersion)
            InfoRow(label: "iPhone", value: "\(DeviceInfo.model), iOS \(DeviceInfo.systemVersion)")
        } header: {
            Text("Installation")
        } footer: {
            Text("Mises à jour : SideStore les propose si tu as ajouté la source de Sommeil (onglet Sources). "
                 + "Sinon, télécharge le dernier Sommeil.ipa dans Safari et ouvre-le dans SideStore. Tes nuits sont gardées.")
        }
    }

    private var diagnosticSection: some View {
        Section {
            Button {
                exportDiagnostic()
            } label: {
                HStack {
                    Label("Exporter le journal de diagnostic", systemImage: "doc.text.magnifyingglass")
                    if preparingExport {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(preparingExport)
        } footer: {
            Text("Un petit fichier (sans les enregistrements eux-mêmes) à m'envoyer si quelque chose ne va pas.")
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
                    model.alert = AlertMessage(title: "Export impossible", message: error.localizedDescription)
                }
            }
        }
    }
}
