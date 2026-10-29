import SwiftUI
import Charts
import SleepCore

/// Rapport de la nuit : note, chiffres clés, chronologie, événements à réécouter, détail de la note.
struct NightReportView: View {
    let report: NightReport
    let item: SessionItem

    @EnvironmentObject private var analysis: NightAnalysisRunner
    @StateObject private var player = ExtractPlayer()

    var body: some View {
        VStack(spacing: 16) {
            ScoreCard(report: report)
            if !report.notes.isEmpty { notesCard }
            KeyFigures(report: report)
            TimelineCard(report: report)
            if !report.summary.positions.isEmpty { PositionsCard(report: report) }
            EventsCard(report: report, directory: item.url, player: player)
            if let score = report.score { ScoreDetails(score: score) }
            Button {
                analysis.enqueue(item.url, first: true)
            } label: {
                Label("Recalculer l'analyse", systemImage: "arrow.clockwise")
                    .font(.footnote)
            }
            .buttonStyle(.borderless)
            .disabled(analysis.current?.sessionID == item.id)
            Text("Calculée le \(Date(timeIntervalSince1970: report.computedUnix).formatted(date: .abbreviated, time: .shortened)). "
                 + Texts.medical)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear { player.stop() }
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(report.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

// MARK: - Note

struct ScoreCard: View {
    let report: NightReport

    static func color(_ value: Int) -> Color {
        if value >= 80 { return .green }
        if value >= 65 { return .teal }
        if value >= 50 { return .orange }
        return .red
    }

    var body: some View {
        let s = report.summary
        HStack(spacing: 18) {
            ZStack {
                ProgressRing(progress: Double(report.score?.value ?? 0) / 100, lineWidth: 10,
                             tint: report.score.map { Self.color($0.value) } ?? .gray)
                VStack(spacing: 0) {
                    Text(report.score.map { "\($0.value)" } ?? "—")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("/ 100").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 100, height: 100)
            VStack(alignment: .leading, spacing: 6) {
                Text(report.score?.verdict ?? "Pas de note")
                    .font(.title3.weight(.bold))
                if report.score == nil {
                    Text("Il faut au moins 2 heures d'enregistrement pour noter la nuit.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Fiabilité : pouls mesuré sur \(s.heartCoverage.percentText) de la nuit, respiration suivie sur "
                     + "\(s.breathCoverage.percentText).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(report.placement == "corps" ? "Téléphone sur la poitrine" : "Téléphone à côté",
                      systemImage: report.placement == "corps" ? "figure.stand" : "bed.double")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
            }
            Spacer(minLength: 0)
        }
        .card()
    }
}

// MARK: - Chiffres clés

struct KeyFigures: View {
    let report: NightReport

    var body: some View {
        let s = report.summary
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            StatTile(icon: "moon.zzz.fill", tint: .indigo, title: "Endormissement probable",
                     value: s.sleepOnsetUnix.map { clockText(Date(timeIntervalSince1970: $0)) } ?? "—",
                     detail: s.sleepOnsetUnix.map { "après \(TimeText.duration($0 - report.startUnix))" } ?? "aucun long moment calme")
            StatTile(icon: "bed.double.fill", tint: .purple, title: "Repos",
                     value: TimeText.duration(s.restSeconds),
                     detail: "calme \(TimeText.duration(s.calmSeconds)) · agité \(TimeText.duration(s.agitatedSeconds))")
            StatTile(icon: "heart.fill", tint: Palette.heart, title: "Pouls",
                     value: s.heartMedian.map { "\(Int($0.rounded())) bpm" } ?? "—",
                     detail: heartDetail(s))
            StatTile(icon: "lungs.fill", tint: .teal, title: "Respiration",
                     value: s.breathMedian.map { "\(Int($0.rounded())) /min" } ?? "—",
                     detail: s.breathCoverage > 0 ? "suivie \(TimeText.duration(s.breathHours * 3600))" : "pas assez nette")
            StatTile(icon: "pause.circle.fill", tint: s.pauses > 0 ? .orange : .green, title: "Pauses possibles",
                     value: "\(s.pauses)",
                     detail: s.pausesPerHour.map { String(format: "%.1f par heure suivie", $0) } ?? "respiration trop peu suivie")
            StatTile(icon: "figure.walk.motion", tint: .orange, title: "Grands mouvements",
                     value: "\(s.bigMovements)",
                     detail: String(format: "%.1f par heure · %d réveil%@ probable%@", s.bigMovementsPerHour, s.awakenings,
                                    s.awakenings > 1 ? "s" : "", s.awakenings > 1 ? "s" : ""))
            StatTile(icon: "waveform.path", tint: .pink, title: "Variabilité du pouls",
                     value: s.rmssd.map { "\(Int($0.rounded())) ms" } ?? "—",
                     detail: s.rmssd == nil ? "téléphone sur la poitrine seulement" : "RMSSD, battements nets")
            StatTile(icon: "zzz", tint: .brown, title: "Ronflements",
                     value: report.soundAnalyzed ? (s.snoreMinutes > 0 ? TimeText.duration(s.snoreMinutes * 60) : "aucun") : "—",
                     detail: report.soundAnalyzed ? "repérés au micro" : "son non analysé")
        }
    }

    private func heartDetail(_ s: NightReport.Summary) -> String {
        if let start = s.heartStart, let end = s.heartEnd {
            return "\(Int(start.rounded())) → \(Int(end.rounded())) · min \(Int((s.heartMin ?? end).rounded()))"
        }
        if let low = s.heartMin { return "min \(Int(low.rounded()))" }
        return "battements peu visibles"
    }
}

// MARK: - Chronologie

struct TimelineCard: View {
    let report: NightReport

    private var start: Date { Date(timeIntervalSince1970: report.startUnix) }
    private var end: Date { Date(timeIntervalSince1970: max(report.endUnix, report.startUnix + 60)) }

    struct Segment: Identifiable {
        var id: Int
        var from: Date
        var to: Date
        var label: String
    }

    struct Point: Identifiable {
        var id: Int
        var date: Date
        var value: Double
        var series: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Chronologie").font(.headline)
            lane("Agitation") {
                Chart {
                    ForEach(report.blocks) { block in
                        RectangleMark(xStart: .value("Début", Date(timeIntervalSince1970: block.startUnix)),
                                      xEnd: .value("Fin", Date(timeIntervalSince1970: block.startUnix + report.blockSeconds)),
                                      yStart: .value("", 0), yEnd: .value("", Self.height(block.level)))
                            .foregroundStyle(by: .value("Niveau", NightReport.levelLabel(block.level)))
                    }
                    ForEach(report.events.filter { $0.kind == "pause" }) { event in
                        RuleMark(x: .value("Pause", Date(timeIntervalSince1970: event.startUnix)))
                            .foregroundStyle(.red)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    }
                }
                .chartForegroundStyleScale(["Calme": Color.indigo, "Mouvements légers": Color.teal,
                                            "Agité": Color.orange, "Pas de mesure": Color.gray.opacity(0.3)])
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...1)
                .chartXScale(domain: start...end)
                .chartXAxis(.hidden)
                .chartLegend(position: .bottom, spacing: 6)
                .frame(height: 92)
            }
            if !positionSegments.isEmpty {
                lane("Position") {
                    Chart(positionSegments) { segment in
                        RectangleMark(xStart: .value("Début", segment.from), xEnd: .value("Fin", segment.to),
                                      yStart: .value("", 0), yEnd: .value("", 1))
                            .foregroundStyle(by: .value("Position", segment.label))
                    }
                    .chartForegroundStyleScale(["Dos": Color.indigo, "Côté gauche": Color.teal, "Côté droit": Color.mint,
                                                "Ventre": Color.purple, "Assis ou debout": Color.orange])
                    .chartYAxis(.hidden)
                    .chartXScale(domain: start...end)
                    .chartXAxis(.hidden)
                    .chartLegend(position: .bottom, spacing: 6)
                    .frame(height: 64)
                }
            }
            if !heartPoints.isEmpty {
                lane("Pouls (bpm)") {
                    Chart(heartPoints) { point in
                        LineMark(x: .value("Heure", point.date), y: .value("Pouls", point.value), series: .value("", point.series))
                            .foregroundStyle(Palette.heart)
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Heure", point.date), y: .value("Pouls", point.value))
                            .foregroundStyle(Palette.heart)
                            .symbolSize(12)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXScale(domain: start...end)
                    .chartXAxis(.hidden)
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                    .frame(height: 90)
                }
            }
            if !breathPoints.isEmpty {
                lane("Respiration (/min)") {
                    Chart(breathPoints) { point in
                        PointMark(x: .value("Heure", point.date), y: .value("Respiration", point.value))
                            .foregroundStyle(by: .value("Source", point.series))
                            .symbolSize(10)
                    }
                    .chartForegroundStyleScale(["mouvement": Color.teal, "son": Color.blue])
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartXScale(domain: start...end)
                    .chartXAxis(.hidden)
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                    .chartLegend(position: .bottom, spacing: 6)
                    .frame(height: 90)
                }
            }
            HStack {
                Text(clockText(start))
                Spacer()
                Text(clockText(end))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .card()
    }

    @ViewBuilder
    private func lane<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    static func height(_ level: String) -> Double {
        switch level {
        case "agite": return 1
        case "leger": return 0.55
        case "calme": return 0.22
        default: return 0.1
        }
    }

    private var positionSegments: [Segment] {
        var result: [Segment] = []
        let positions = report.epochs.position
        var i = 0
        while i < positions.count {
            let code = positions[i]
            var j = i
            while j + 1 < positions.count, positions[j + 1] == code { j += 1 }
            if !code.isEmpty {
                result.append(Segment(id: i, from: Date(timeIntervalSince1970: report.startUnix + Double(i) * report.epochSeconds),
                                      to: Date(timeIntervalSince1970: report.startUnix + Double(j + 1) * report.epochSeconds),
                                      label: NightReport.positionLabel(code)))
            }
            i = j + 1
        }
        return result
    }

    private var heartPoints: [Point] {
        var points: [Point] = []
        var series = 0
        var previousMissing = true
        for (index, block) in report.blocks.enumerated() {
            guard let bpm = block.heartBPM else {
                previousMissing = true
                continue
            }
            if previousMissing { series += 1 }
            previousMissing = false
            points.append(Point(id: index, date: Date(timeIntervalSince1970: block.startUnix + report.blockSeconds / 2),
                                value: bpm, series: "s\(series)"))
        }
        return points
    }

    private var breathPoints: [Point] {
        report.epochs.breathRate.enumerated().compactMap { index, rate in
            guard let rate else { return nil }
            return Point(id: index, date: Date(timeIntervalSince1970: report.startUnix + (Double(index) + 0.5) * report.epochSeconds),
                         value: rate, series: report.epochs.breathSource[index])
        }
    }
}

// MARK: - Positions

struct PositionsCard: View {
    let report: NightReport

    var body: some View {
        let total = max(1, report.summary.positions.values.reduce(0, +))
        VStack(alignment: .leading, spacing: 10) {
            Text("Positions").font(.headline)
            ForEach(report.summary.positions.sorted { $0.value > $1.value }, id: \.key) { code, seconds in
                HStack {
                    Text(NightReport.positionLabel(code)).font(.subheadline)
                    Spacer()
                    Text(TimeText.duration(seconds)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
                QualityBarPlain(value: seconds / total, tint: .indigo)
            }
        }
        .card()
    }
}

struct QualityBarPlain: View {
    let value: Double
    var tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(tint).frame(width: max(6, geometry.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Événements

struct EventsCard: View {
    let report: NightReport
    let directory: URL
    @ObservedObject var player: ExtractPlayer

    private var shown: [NightReport.Event] {
        report.events.filter { $0.kind != "trou" || $0.duration >= 5 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Événements").font(.headline)
            if shown.isEmpty {
                Label("Rien à signaler.", systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
            ForEach(shown) { event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: Self.icon(event.kind))
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Self.tint(event.kind).gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(event.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(clockText(Date(timeIntervalSince1970: event.startUnix)))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Text(event.detail).font(.caption).foregroundStyle(.secondary)
                        if event.hasSound {
                            Button {
                                player.toggle(id: event.id, unix: event.startUnix, directory: directory)
                            } label: {
                                Label(player.playingID == event.id ? "Arrêter" : "Réécouter (30 s)",
                                      systemImage: player.playingID == event.id ? "stop.fill" : "play.fill")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.borderless)
                            .padding(.top, 2)
                        }
                    }
                }
            }
        }
        .card()
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "pause": return "pause.fill"
        case "chute": return "arrow.down.to.line"
        case "telephone_deplace": return "iphone.gen3.radiowaves.left.and.right"
        case "ronflement": return "zzz"
        case "interruption": return "speaker.slash.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    static func tint(_ kind: String) -> Color {
        switch kind {
        case "pause": return .red
        case "chute", "telephone_deplace": return .orange
        case "ronflement": return .brown
        default: return .gray
        }
    }
}

// MARK: - Détail de la note

struct ScoreDetails: View {
    let score: NightReport.Score

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Détail de la note").font(.headline)
            ForEach(score.parts) { part in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(part.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Int(part.points.rounded())) pts · \(Int((part.weight * 100).rounded())) %")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    QualityBarPlain(value: part.points / 100, tint: ScoreCard.color(Int(part.points)))
                    Text(part.measure).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Repères fixés à l'avance, sans validation médicale. Compare surtout des nuits avec le téléphone au même endroit.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

/// Encadré d'attente ou de progression de l'analyse.
struct AnalysisStatusCard: View {
    let item: SessionItem
    @EnvironmentObject private var analysis: NightAnalysisRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let progress = analysis.current, progress.sessionID == item.id {
                HStack {
                    Label("Analyse de la nuit", systemImage: "waveform.path.ecg")
                        .font(.headline)
                    Spacer()
                    Text("\(Int((progress.fraction * 100).rounded())) %")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                ProgressView(value: progress.fraction)
                    .tint(.indigo)
                    .animation(.easeInOut, value: progress.fraction)
                Text(progress.step + " · garde l'app ouverte, environ une minute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if analysis.isWaiting(item.id) {
                Label("Analyse en attente…", systemImage: "hourglass")
                    .font(.headline)
                Text("Une autre nuit est en cours d'analyse.").font(.caption).foregroundStyle(.secondary)
            } else {
                if let failure = analysis.failures[item.id] {
                    Label("L'analyse a échoué : \(failure)", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Text("Pas encore de rapport pour cet enregistrement.")
                    .font(.subheadline)
                Button {
                    analysis.enqueue(item.url, first: true)
                } label: {
                    Label("Analyser la nuit", systemImage: "wand.and.stars")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .prominentButton()
                .tint(.indigo)
            }
        }
        .card()
    }
}
