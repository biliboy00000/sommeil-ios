import SwiftUI
import SleepCore

/// Écran affiché pendant un enregistrement (nuit ou test guidé).
struct RecordingView: View {
    @EnvironmentObject private var recorder: Recorder
    @State private var confirmStop = false

    var body: some View {
        let live = recorder.live
        NavigationStack {
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
