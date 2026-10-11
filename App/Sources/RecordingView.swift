import SwiftUI
import SleepCore

/// Écran affiché pendant un enregistrement (nuit ou test guidé), ou pendant l'attente d'une nuit programmée.
struct RecordingView: View {
    @EnvironmentObject private var recorder: Recorder
    @State private var confirmStop = false
    @State private var confirmCancel = false

    var body: some View {
        if recorder.isWaiting {
            waitingBody
        } else {
            recordingBody
        }
    }

    // MARK: - Nuit programmée

    private var waitingBody: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, (recorder.waitUntil ?? context.date).timeIntervalSince(context.date))
                        Text(Self.countdown(remaining))
                            .font(.system(size: 52, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    if let until = recorder.waitUntil {
                        Text("La nuit commencera à \(until.formatted(date: .omitted, time: .shortened))")
                            .font(.headline)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("En attente", systemImage: "moon.zzz").font(.headline)
                        Text("Attache le téléphone, verrouille l'écran et ne ferme pas l'app. Le micro est allumé pour "
                             + "que l'app reste active, mais rien n'est enregistré avant l'heure prévue. Ensuite, pas de "
                             + "voix : la calibration se fera toute seule pendant un moment calme sur le dos.")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.1)))
                    Text(Texts.charging)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        recorder.finishWaiting(automatic: false)
                    } label: {
                        Text("Commencer maintenant").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(role: .destructive) {
                        confirmCancel = true
                    } label: {
                        Text("Annuler la nuit").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle("Nuit programmée")
            .navigationBarTitleDisplayMode(.inline)
        }
        .confirmationDialog("Annuler la nuit programmée ?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Annuler la nuit", role: .destructive) { recorder.cancelWaiting() }
            Button("Continuer d'attendre", role: .cancel) {}
        }
    }

    /// « 44:59 » ou « 1:05:00 ».
    static func countdown(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: - Enregistrement

    private var recordingBody: some View {
        let live = recorder.live
        return NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text(TimeText.duration(live.elapsed))
                        .font(.system(size: 52, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    phaseCard(live)
                    statsCard(live)
                    if let message = live.lastMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(recorder.kind == .night
                         ? "Tu peux verrouiller l'écran. Ne ferme pas l'app depuis le sélecteur d'apps. "
                           + Texts.charging
                         : "Garde l'écran allumé pendant le test, et monte le volume pour entendre les consignes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(role: .destructive) {
                        confirmStop = true
                    } label: {
                        Text("Arrêter").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding()
            }
            .navigationTitle(recorder.kind.label)
            .navigationBarTitleDisplayMode(.inline)
        }
        .confirmationDialog("Arrêter l'enregistrement ?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Arrêter", role: .destructive) { recorder.stop() }
            Button("Continuer", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func phaseCard(_ live: Recorder.Live) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let remaining = live.calibrationRemaining {
                Label("Calibration : allongé sur le dos, sans bouger", systemImage: "figure.mind.and.body")
                    .font(.headline)
                Text("Encore \(Int(remaining.rounded(.up))) s").font(.title3).monospacedDigit()
            } else if live.autoCalibrating {
                Label("Calibration automatique", systemImage: "figure.mind.and.body").font(.headline)
                Text("Elle se fera toute seule dès que tu seras calme sur le dos (30 secondes). Rien à faire.")
                    .font(.subheadline)
                Button {
                    recorder.recalibrate()
                } label: {
                    Label("La faire maintenant (30 s sur le dos)", systemImage: "arrow.counterclockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            } else if recorder.kind == .guided, let display = live.guidedDisplay {
                Label(display, systemImage: "person.wave.2").font(.headline)
                if let next = live.guidedNext {
                    Text(next).font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Label("Enregistrement en cours", systemImage: "waveform.path.ecg").font(.headline)
                if let tilt = live.calibrationTilt, tilt > Calibration.maxPlausibleTilt {
                    Text("Le téléphone était incliné de \(Int(tilt.rounded()))° pendant la calibration : "
                         + "si tu n'étais pas sur le dos, recommence-la.")
                        .font(.footnote).foregroundStyle(.orange)
                } else if let movement = live.calibrationMovement, movement >= Calibration.maxStillMovement {
                    Text("Tu as bougé pendant la calibration : la position « sur le dos » sera moins précise.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Button {
                    recorder.recalibrate()
                } label: {
                    Label("Recommencer la calibration (30 s sur le dos)", systemImage: "arrow.counterclockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.1)))
    }

    private func statsCard(_ live: Recorder.Live) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(["dm", "acc", "gyr"], id: \.self) { stream in
                if let count = live.samples[stream] {
                    let rate = live.rates[stream].map { String(format: "%.1f Hz", $0) } ?? "…"
                    let jitter = live.jitterMs[stream].map { String(format: " ±%.1f ms", $0) } ?? ""
                    InfoRow(label: Self.streamLabel(stream), value: "\(rate)\(jitter) · \(count) mesures")
                }
            }
            InfoRow(label: "Trous dans les capteurs", value: "\(live.gaps)", valueColor: live.gaps > 0 ? .orange : .primary)
            InfoRow(label: "Son", value: live.audioRunning
                    ? "\(TimeText.duration(live.audioSeconds)) · \(Int(live.level)) dB"
                    : "arrêté — relance en cours",
                    valueColor: live.audioRunning ? .primary : .red)
            if let yeti = live.yetiText {
                InfoRow(label: "Blue Yeti (PC)", value: yeti, valueColor: live.yetiOK ? .primary : .orange)
            }
            InfoRow(label: "Interruptions", value: "\(live.interruptions)")
            if let battery = live.battery {
                InfoRow(label: "Batterie", value: battery.percentText, valueColor: battery < 0.15 ? .red : .primary)
            }
        }
        .font(.subheadline)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.1)))
    }

    static func streamLabel(_ stream: String) -> String {
        switch stream {
        case "dm": return "Mouvement"
        case "acc": return "Accéléromètre brut"
        case "gyr": return "Gyroscope brut"
        default: return stream
        }
    }
}
