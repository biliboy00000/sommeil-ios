import SwiftUI
import Charts
import SleepCore

/// Onglet « Cœur » : téléphone posé sur la poitrine, l'activité du cœur en direct.
/// Rien n'est enregistré. Sert aussi à trouver le meilleur emplacement et le bon serrage pour la nuit.
struct HeartView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var heart: HeartMonitor
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    @State private var visible = false
    @State private var notes: [PlacementNote] = []
    @State private var place = PlacementNote.places[0]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    MonitorCard(mode: traceMode)
                    Picker("Tracé", selection: $settings.heartTrace) {
                        Text("Vibrations").tag("signal")
                        Text("Battements").tag("pouls")
                    }
                    .pickerStyle(.segmented)
                    guidance
                    rhythmCard
                    HStack(alignment: .top, spacing: 12) {
                        variabilityTile
                        breathTile
                    }
                    placementCard
                    Text("Rien n'est enregistré sur cet écran. " + Texts.medical)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Cœur")
            .animation(.snappy, value: heart.state)
        }
        .onAppear {
            visible = true
            startIfPossible()
        }
        .onDisappear {
            visible = false
            recorder.stopLive()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startIfPossible() } else { recorder.stopLive() }
        }
    }

    private var traceMode: MonitorCard.Mode { settings.heartTrace == "pouls" ? .pulse : .signal }

    private func startIfPossible() {
        guard visible, scenePhase == .active, !recorder.isRecording, !recorder.isWaiting else { return }
        recorder.startLive()
    }

    // MARK: - Consignes

    @ViewBuilder
    private var guidance: some View {
        switch heart.state {
        case .starting, .searching:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "iphone.gen3")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, isActive: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(heart.state == .starting ? "Mise en route…" : "Recherche des battements…")
                        .font(.headline)
                    Text("Allonge-toi sur le dos et pose le téléphone à plat sur le bas du sternum, écran vers le "
                         + "haut. Ne bouge plus, respire normalement : les battements apparaissent en 5 à 15 secondes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .card()
            .transition(.opacity.combined(with: .move(edge: .top)))
        case .moving:
            Label("Tu bouges : reste immobile quelques secondes.", systemImage: "figure.walk.motion")
                .font(.headline)
                .foregroundStyle(.orange)
                .card()
                .transition(.opacity.combined(with: .move(edge: .top)))
        case .tracking:
            EmptyView()
        }
    }

    // MARK: - Rythme battement par battement

    private var rhythmCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Rythme, battement par battement", systemImage: "waveform.path.ecg")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("60 s").font(.caption).foregroundStyle(.secondary)
            }
            if heart.intervals.count >= 3 {
                Chart(heart.intervals, id: \.time) { interval in
                    LineMark(x: .value("Temps", interval.time), y: .value("Pouls", 60 / interval.seconds))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Palette.heart)
                    PointMark(x: .value("Temps", interval.time), y: .value("Pouls", 60 / interval.seconds))
                        .symbolSize(14)
                        .foregroundStyle(Palette.heart)
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
                }
                .frame(height: 110)
                .animation(.easeInOut(duration: 0.4), value: heart.intervals.count)
                Text("Chaque point est un battement : la hauteur donne le pouls de cet intervalle. Il monte un peu "
                     + "quand tu inspires et baisse quand tu expires : c'est normal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Les battements s'afficheront ici dès qu'ils seront repérés.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }
        }
        .card()
    }

    private var variabilityTile: some View {
        StatTile(icon: "waveform", tint: .purple, title: "Variabilité",
                 value: heart.rmssd.map { "\(Int($0.rounded())) ms" } ?? "—",
                 detail: heart.rmssd == nil ? "après 20 battements nets" : "RMSSD, estimation")
    }

    private var breathTile: some View {
        let breath = heart.breath
        let value = breath?.perMinute.map { "\(Int($0.rounded())) /min" } ?? "—"
        let detail: String
        if heart.secondsBuffered < 20 {
            detail = "après 20 s de mesure"
        } else if let breath, breath.quality >= 0.5 {
            detail = "nette"
        } else {
            detail = "peu nette"
        }
        return StatTile(icon: "lungs.fill", tint: .teal, title: "Respiration", value: value, detail: detail)
    }

    // MARK: - Comparer des emplacements

    private var placementCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Comparer des emplacements", systemImage: "scope")
                .font(.subheadline.weight(.semibold))
            Text("Pour les nuits avec le téléphone sur toi : essaie plusieurs endroits et serrages, et note chacun "
                 + "après 15 secondes immobile. Garde celui qui a la meilleure note « cœur ».")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Picker("Emplacement", selection: $place) {
                    ForEach(PlacementNote.places, id: \.self) { Text($0) }
                }
                .labelsHidden()
                Spacer()
                Button("Noter") { addNote() }
                    .secondaryButton()
                    .disabled(heart.recentQuality.count < 5)
            }
            ForEach(notes) { note in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.place).font(.subheadline.weight(.semibold))
                        Text("cœur \(Int(note.heart * 100))/100 · respiration \(Int(note.breath * 100))/100"
                             + (note.bpm.map { String(format: " · %.0f bpm", $0) } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    QualityBar(value: note.heart, height: 6).frame(width: 60)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .card()
        .animation(.snappy, value: notes.count)
    }

    private func addNote() {
        let history = heart.recentQuality
        guard !history.isEmpty else { return }
        let heartQuality = history.map(\.heart).reduce(0, +) / Double(history.count)
        let breathQuality = history.map(\.breath).reduce(0, +) / Double(history.count)
        let rates = history.compactMap(\.bpm)
        let bpm = rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count)
        notes.insert(PlacementNote(place: place, heart: heartQuality, breath: breathQuality, bpm: bpm), at: 0)
        Diagnostics.shared.log(String(format: "Emplacement noté : %@ — cœur %.2f, respiration %.2f, %@", place,
                                      heartQuality, breathQuality, bpm.map { String(format: "%.0f bpm", $0) } ?? "pouls ?"))
    }
}

struct PlacementNote: Identifiable {
    let id = UUID()
    let place: String
    let heart: Double
    let breath: Double
    let bpm: Double?

    static let places = ["Bas du sternum", "Milieu du sternum", "Sur le cœur (à gauche)", "Sous les côtes", "Autre"]
}

/// Le moniteur : pouls, cœur qui bat et tracé qui défile.
struct MonitorCard: View {
    enum Mode { case signal, pulse }

    let mode: Mode
    @EnvironmentObject private var heart: HeartMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: heart.state == .tracking ? "heart.fill" : "heart")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(heart.state == .tracking ? Palette.heart : Color.white.opacity(0.5))
                    .symbolEffect(.bounce, value: heart.beatCount)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(heart.bpm.map { "\(Int($0.rounded()))" } ?? "—")
                            .font(.system(size: 52, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: heart.bpm ?? 0))
                            .animation(.snappy, value: heart.bpm.map { Int($0.rounded()) })
                        Text("bpm")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .contentTransition(.opacity)
                }
                .foregroundStyle(.white)
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    signalBadge
                    if !heart.channel.isEmpty {
                        Text(heart.channel)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            HeartTrace(mode: mode)
                .frame(height: 170)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [Palette.monitor, Color(red: 0.06, green: 0.09, blue: 0.11)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.06))
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heart.bpm.map { "Pouls \(Int($0.rounded())) battements par minute" } ?? statusText)
    }

    private var statusText: String {
        switch heart.state {
        case .starting: return "Mise en route"
        case .searching:
            if let average = heart.averageBPM { return String(format: "Recherche des battements · environ %.0f", average) }
            return "Recherche des battements"
        case .tracking: return heart.intervals.last.map { String(format: "Dernier intervalle %.2f s", $0.seconds) } ?? "Battements repérés"
        case .moving: return "Mouvement : mesure en pause"
        }
    }

    private var signalBadge: some View {
        let q = heart.quality
        let text: String
        let color: Color
        if q >= 0.5 {
            text = "Signal net"
            color = Color.green
        } else if q >= 0.3 {
            text = "Signal faible"
            color = Color.orange
        } else {
            text = "Pas de signal"
            color = Color.red
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassPill(tint: color)
    }
}

/// Tracé qui défile en continu (jusqu'à 120 images par seconde), lu dans `HeartMonitor`.
struct HeartTrace: View {
    let mode: MonitorCard.Mode
    @EnvironmentObject private var heart: HeartMonitor
    @State private var gain = GainState()

    /// Secondes affichées, et retard du tracé : laisse le temps de confirmer chaque battement
    /// (il apparaît ainsi au bon endroit avant d'atteindre le bord droit).
    static let window = 6.0
    static let delay = 0.45

    final class GainState {
        var scale = 4.0
    }

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let now = ProcessInfo.processInfo.systemUptime - Self.delay
                let start = now - Self.window
                let snapshot = heart.snapshot(since: start - 0.1)
                drawGrid(ctx, size: size)
                guard snapshot.points.count > 2 else { return }
                let x = { (t: Double) -> CGFloat in CGFloat((t - start) / Self.window) * size.width }
                let visible = snapshot.points.filter { $0.time <= now }
                guard visible.count > 2 else { return }

                // Échelle automatique, qui suit en douceur.
                let values = visible.map { Double(mode == .signal ? abs($0.signal) : $0.envelope) }
                let target = max(mode == .signal ? 3 : 2.5, DSP.percentile(values, 99) * 1.15)
                gain.scale += (target - gain.scale) * 0.06
                let scale = gain.scale
                let mid = mode == .signal ? size.height * 0.5 : size.height * 0.9
                let amplitude = mode == .signal ? size.height * 0.46 : size.height * 0.82
                let y = { (v: Float) -> CGFloat in
                    let value = mode == .signal ? Double(v) : Double(v) - 1
                    return mid - CGFloat(max(-1.1, min(1.1, value / scale))) * amplitude
                }

                var path = Path()
                for (i, point) in visible.enumerated() {
                    let p = CGPoint(x: x(point.time), y: y(mode == .signal ? point.signal : point.envelope))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                let color = heart.state == .tracking ? Palette.trace : Palette.trace.opacity(0.55)
                if mode == .pulse {
                    var area = path
                    area.addLine(to: CGPoint(x: x(visible[visible.count - 1].time), y: mid))
                    area.addLine(to: CGPoint(x: x(visible[0].time), y: mid))
                    area.closeSubpath()
                    ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]),
                                                        startPoint: CGPoint(x: 0, y: mid - amplitude),
                                                        endPoint: CGPoint(x: 0, y: mid)))
                }
                // Halo puis trait fin.
                ctx.stroke(path, with: .color(color.opacity(0.25)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                // Battements : un point rouge au-dessus du sommet.
                for beat in snapshot.beats where beat.time <= now {
                    let bx = x(beat.time - 0.04)
                    let marker = CGRect(x: bx - 3.5, y: 6, width: 7, height: 7)
                    ctx.fill(Path(ellipseIn: marker), with: .color(Palette.heart))
                    var tick = Path()
                    tick.move(to: CGPoint(x: bx, y: 15))
                    tick.addLine(to: CGPoint(x: bx, y: size.height))
                    ctx.stroke(tick, with: .color(Palette.heart.opacity(0.18)), lineWidth: 1)
                }

                // Tête du tracé.
                if let last = visible.last {
                    let head = CGPoint(x: x(last.time), y: y(mode == .signal ? last.signal : last.envelope))
                    ctx.fill(Path(ellipseIn: CGRect(x: head.x - 7, y: head.y - 7, width: 14, height: 14)),
                             with: .color(color.opacity(0.25)))
                    ctx.fill(Path(ellipseIn: CGRect(x: head.x - 3, y: head.y - 3, width: 6, height: 6)), with: .color(color))
                }
            }
        }
        .mask {
            LinearGradient(stops: [.init(color: .black.opacity(0.15), location: 0),
                                   .init(color: .black, location: 0.35),
                                   .init(color: .black, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .accessibilityHidden(true)
    }

    private func drawGrid(_ ctx: GraphicsContext, size: CGSize) {
        var grid = Path()
        let columns = 12
        for i in 1..<columns {
            let gx = size.width * CGFloat(i) / CGFloat(columns)
            grid.move(to: CGPoint(x: gx, y: 0))
            grid.addLine(to: CGPoint(x: gx, y: size.height))
        }
        for i in 1..<4 {
            let gy = size.height * CGFloat(i) / 4
            grid.move(to: CGPoint(x: 0, y: gy))
            grid.addLine(to: CGPoint(x: size.width, y: gy))
        }
        ctx.stroke(grid, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
    }
}
