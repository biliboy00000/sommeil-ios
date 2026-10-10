import SwiftUI
import SleepCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var uploader: Uploader
    @EnvironmentObject private var model: AppModel

    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                TextField("ex. 192.168.1.23:8010", text: $settings.pcAddress)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    testing = true
                    testResult = nil
                    Task {
                        let result = await uploader.ping(address: settings.pcAddress)
                        await MainActor.run {
                            testResult = result
                            testing = false
                        }
                    }
                } label: {
                    if testing { ProgressView() } else { Text("Tester la connexion") }
                }
                .disabled(settings.pcAddress.isEmpty || testing)
                if let testResult { Text(testResult).font(.footnote) }
                Toggle("Envoyer automatiquement à l'arrêt", isOn: $settings.autoUpload)
            } header: {
                Text("Adresse du PC")
            } footer: {
                Text("Double-clique sur 5_RECEVOIR_IPHONE.bat sur le PC : il affiche l'adresse à recopier ici. "
                     + "Le PC et l'iPhone doivent être sur le même Wi-Fi. La première fois, l'iPhone demande "
                     + "l'accès au réseau local : réponds « Autoriser ».")
            }

            Section {
                DatePicker("Heure du réveil", selection: Binding(get: { settings.wakeDate },
                                                                 set: { settings.wakeDate = $0 }),
                           displayedComponents: .hourAndMinute)
                Toggle("Consignes à voix haute", isOn: $settings.voicePrompts)
                Toggle("Capteurs bruts en plus", isOn: $settings.rawSensors)
            } header: {
                Text("Enregistrement")
            } footer: {
                Text("L'heure du réveil sert à prévoir la batterie restante le matin. « Capteurs bruts » enregistre "
                     + "aussi l'accéléromètre et le gyroscope non traités par iOS : utile pour la phase de test, "
                     + "un peu plus de batterie et de stockage.")
            }

            Section("Installation") {
                if let info = model.installation {
                    if let expiry = info.expiration {
                        InfoRow(label: "Valable jusqu'au", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let team = info.teamName { InfoRow(label: "Signée par", value: team) }
                } else {
                    Text("Profil d'installation introuvable.").foregroundStyle(.secondary)
                }
                InfoRow(label: "Version de l'app", value: DeviceInfo.appVersion)
                InfoRow(label: "iPhone", value: "\(DeviceInfo.model), iOS \(DeviceInfo.systemVersion)")
            }

            Section {
                Text(Texts.medical).font(.footnote)
                Text(Texts.charging).font(.footnote)
            }
        }
        .navigationTitle("Réglages")
    }
}
