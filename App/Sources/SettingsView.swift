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
                SecureField("Code du PC (6 chiffres)", text: $settings.pcCode)
                    .keyboardType(.numberPad)
                Toggle("Lancer le Blue Yeti avec chaque enregistrement", isOn: $settings.controlYeti)
                Button {
                    testing = true
                    testResult = nil
                    Task {
                        var result = await uploader.ping(address: settings.pcAddress)
                        if settings.controlYeti {
                            let yeti = await PCLink.status(address: settings.pcAddress, code: settings.pcCode)
                            switch yeti {
                            case .state(let state):
                                result += state.enregistre == true
                                    ? " Le Blue Yeti enregistre déjà."
                                    : " Code accepté : le Blue Yeti démarrera avec la prochaine nuit."
                            case .failure(let message):
                                result += " Blue Yeti : \(message)."
                            }
                        }
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
                Text("Double-clique sur 5_RECEVOIR_IPHONE.bat sur le PC : il affiche l'adresse et le code à "
                     + "recopier ici. Le PC et l'iPhone doivent être sur le même Wi-Fi. La première fois, l'iPhone "
                     + "demande l'accès au réseau local : réponds « Autoriser ». Avec le code, « Commencer la nuit » "
                     + "lance aussi le Blue Yeti du PC, et « Arrêter » l'arrête.")
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
