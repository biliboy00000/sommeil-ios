import SwiftUI
import SleepCore

/// Écran affiché pendant un enregistrement (nuit ou test guidé), ou pendant l'attente d'une nuit programmée.
/// Sombre et calme : il reste peu de lumière dans la chambre.
struct RecordingView: View {
    @EnvironmentObject private var recorder: Recorder
    @State private var confirmCancel = false
    @State private var showDetails = false
    @State private var stopFeedback = 0

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black, Palette.nightTop, Palette.nightBottom.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            Starfield(count: 50)
                .ignoresSafeArea()
                .opacity(0.6)
            if recorder.isWaiting {
                waitingBody
                    .transition(.opacity)
            } else {
                recordingBody
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: recorder.isWaiting)
        .preferredColorScheme(.dark)
        .confirmationDialog("Annuler la nuit programmée ?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Annuler la nuit", role: .destructive) { recorder.cancelWaiting() }
            Button("Continuer d'attendre", role: .cancel) {}
        }
    }

    // MARK: - Nuit programmée

    private var waitingBody: some View {
        VStack(spacing: 24) {
            header(title: "Nuit programmée", subtitle: recorder.waitUntil.map { "Début à \(clockText($0))" } ?? "")
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let until = recorder.waitUntil ?? context.date
                let remaining = max(0, until.timeIntervalSince(context.date))
                let total = max(60, Double(recorder.waitTotalSeconds))
                ZStack {
                    ProgressRing(progress: 1 - remaining / total, lineWidth: 6, tint: Palette.moon,
                                 track: .white.opacity(0.12))
                        .frame(width: 250, height: 250)
                    VStack(spacing: 6) {
                        Image(systemName: "moon.zzz.fill")
                            .font(.title2)
                            .foregroundStyle(Palette.moon)
                            .symbolEffect(.pulse)
                        Text(Self.countdown(remaining))
                            .font(.system(size: 54, weight: .light, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.snappy, value: Int(remaining))
                        Text("avant le début")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Verrouille l'écran, ne ferme pas l'app. Rien n'est enregistré avant l'heure prévue ; ensuite, "
                 + "pas de voix : la calibration se fera toute seule pendant un moment calme.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
            VStack(spacing: 12) {
                Button {
                    recorder.finishWaiting(automatic: false)
                } label: {
                    Label("Commencer maintenant", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .prominentButton()
                .tint(.indigo)
                Button("Annuler la nuit", role: .destructive) { confirmCancel = true }
                    .font(.subheadline)
            }
        }
        .foregroundStyle(.white)
        .padding(24)
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
        return ScrollView {
            VStack(spacing: 22) {
                header(title: recorder.kind == .night ? "Nuit en cours" : "Test guidé",
                       subtitle: recorder.startDate.map { "Depuis \(clockText($0))" } ?? "")
                centerDial(live)
                    .padding(.vertical, 8)
                phaseCard(live)
                statusPills(live)
                details(live)
                if let message = live.lastMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(recorder.kind == .night
                     ? "Tu peux verrouiller l'écran. Ne ferme pas l'app depuis le sélecteur d'apps. " + Texts.charging
                     : "Garde l'écran allumé pendant le test, et monte le volume pour entendre les consignes.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HoldButton(title: "Maintenir pour arrêter") { recorder.stop() }
                    .padding(.top, 4)
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .scrollIndicators(.hidden)
    }

    private func header(title: String, subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                    .opacity(recorder.isRecording ? 1 : 0.3)
                Text(recorder.isRecording ? "REC" : "attente")
                    .font(.caption.weight(.bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassPill()
        }
    }

    /// Cadran central : durée, anneau de calibration ou halo qui « respire » lentement.
    private func centerDial(_ live: Recorder.Live) -> some View {
        ZStack {
            if let remaining = live.calibrationRemaining {
                ProgressRing(progress: 1 - remaining / Recorder.calibrationSeconds, lineWidth: 7,
                             tint: Palette.moon, track: .white.opacity(0.12))
                    .frame(width: 240, height: 240)
            } else {
                BreathingHalo()
                    .frame(width: 240, height: 240)
            }
            VStack(spacing: 4) {
                Text(Self.clock(live.elapsed))
                    .font(.system(size: 52, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: Int(live.elapsed))
                if let remaining = live.calibrationRemaining {
                    Text("calibration : \(Int(remaining.rounded(.up))) s")
                        .font(.subheadline)
                        .foregroundStyle(Palette.moon)
                        .monospacedDigit()
                } else {
                    Text("enregistré")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    /// « 2:14:05 ».
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    @ViewBuilder
    private func phaseCard(_ live: Recorder.Live) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if live.calibrationRemaining != nil {
                if recorder.placement == "a_cote" {
                    Label("Ne touche plus le téléphone", systemImage: "iphone.gen3")
                        .font(.headline)
                    Text("30 secondes pour mesurer le calme de la pièce. Ensuite, verrouille l'écran.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Label("Allongé sur le dos, sans bouger", systemImage: "figure.mind.and.body")
                        .font(.headline)
                    Text("30 secondes pour connaître la position « sur le dos ». Respire normalement.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else if live.autoCalibrating {
                Label("Calibration automatique", systemImage: "figure.mind.and.body").font(.headline)
                Text("Elle se fera toute seule dès que tu seras calme sur le dos. Rien à faire.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                Button {
                    recorder.recalibrate()
                } label: {
                    Label("La faire maintenant (30 s)", systemImage: "arrow.counterclockwise")
                        .font(.subheadline)
                }
                .secondaryButton()
            } else if recorder.kind == .guided, let display = live.guidedDisplay {
                Label(display, systemImage: "person.wave.2")
                    .font(.headline)
                    .contentTransition(.opacity)
                if let next = live.guidedNext {
                    Text(next).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                }
            } else {
                Label("Bonne nuit", systemImage: "moon.stars.fill")
                    .font(.headline)
                    .foregroundStyle(Palette.moon)
                if let tilt = live.calibrationTilt, tilt > Calibration.maxPlausibleTilt {
                    Text("Le téléphone était incliné de \(Int(tilt.rounded()))° pendant la calibration : "
                         + "si tu n'étais pas sur le dos, recommence-la.")
                        .font(.footnote).foregroundStyle(.orange)
                } else if let movement = live.calibrationMovement, movement >= Calibration.maxStillMovement {
                    Text("Tu as bougé pendant la calibration : la position « sur le dos » sera moins précise.")
                        .font(.footnote).foregroundStyle(.orange)
                } else {
                    Text("Tout s'enregistre. Tu peux verrouiller l'écran.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Button {
                    recorder.recalibrate()
                } label: {
                    Label("Recommencer la calibration", systemImage: "arrow.counterclockwise")
                        .font(.subheadline)
                }
                .secondaryButton()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.snappy, value: live.calibrationRemaining == nil)
    }

    private func statusPills(_ live: Recorder.Live) -> some View {
        let rate = live.rates["dm"]
        let sensorsOK = (rate ?? 0) > 90 || live.samples.isEmpty
        return HStack(spacing: 10) {
            pill(icon: "waveform.path.ecg", text: rate.map { "\(Int($0.rounded())) Hz" } ?? "capteurs",
                 ok: sensorsOK)
            pill(icon: live.audioRunning ? "mic.fill" : "mic.slash.fill",
                 text: live.audioRunning ? "son" : "relance…", ok: live.audioRunning)
            if let battery = live.battery {
                pill(icon: battery < 0.15 ? "battery.25percent" : "battery.75percent",
                     text: battery.percentText, ok: battery >= 0.15)
            }
        }
    }

    private func pill(icon: String, text: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption.weight(.semibold))
            Text(text).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(ok ? .white : .orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .glassPill(tint: ok ? nil : .orange)
    }

    private func details(_ live: Recorder.Live) -> some View {
        DisclosureGroup(isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(["dm", "acc", "gyr"], id: \.self) { stream in
                    if let count = live.samples[stream] {
                        let rate = live.rates[stream].map { String(format: "%.1f Hz", $0) } ?? "…"
                        let jitter = live.jitterMs[stream].map { String(format: " ±%.1f ms", $0) } ?? ""
                        InfoRow(label: Self.streamLabel(stream), value: "\(rate)\(jitter) · \(count)")
                    }
                }
                InfoRow(label: "Trous dans les capteurs", value: "\(live.gaps)",
                        valueColor: live.gaps > 0 ? .orange : .primary)
                InfoRow(label: "Son", value: live.audioRunning
                        ? "\(TimeText.duration(live.audioSeconds)) · \(Int(live.level)) dB"
                        : "arrêté — relance en cours",
                        valueColor: live.audioRunning ? .primary : .red)
                InfoRow(label: "Interruptions", value: "\(live.interruptions)")
            }
            .font(.footnote)
            .padding(.top, 8)
        } label: {
            Text("Détails techniques").font(.subheadline).foregroundStyle(.white.opacity(0.7))
        }
        .tint(.white.opacity(0.7))
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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

/// Halo qui grandit et rétrécit lentement (environ six respirations par minute) : apaisant, et montre que l'app tourne.
struct BreathingHalo: View {
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Palette.nightBottom.opacity(0.9), .clear],
                                     center: .center, startRadius: 10, endRadius: 140))
                .scaleEffect(expanded ? 1.08 : 0.86)
            Circle()
                .strokeBorder(.white.opacity(expanded ? 0.18 : 0.08), lineWidth: 1)
                .scaleEffect(expanded ? 1.0 : 0.9)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) { expanded = true }
        }
        .accessibilityHidden(true)
    }
}
