import SwiftUI
import SleepCore

/// Onglet « Nuits » : tous les enregistrements, regroupés par mois.
struct NightsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingDelete: SessionItem?

    private var groups: [(month: String, items: [SessionItem])] {
        var result: [(String, [SessionItem])] = []
        for item in model.sessions {
            let date = item.startDate ?? .distantPast
            let month = date.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "fr_FR")))
            let label = month.prefix(1).uppercased() + month.dropFirst()
            if let index = result.firstIndex(where: { $0.0 == label }) {
                result[index].1.append(item)
            } else {
                result.append((label, [item]))
            }
        }
        return result.map { (month: $0.0, items: $0.1) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.sessions.isEmpty {
                    ContentUnavailableView("Aucune nuit pour l'instant", systemImage: "moon.zzz",
                                           description: Text("Lance ta première nuit depuis l'onglet « Ce soir »."))
                } else {
                    List {
                        ForEach(groups, id: \.month) { group in
                            Section(group.month) {
                                ForEach(group.items) { item in
                                    NavigationLink { SessionDetailView(item: item) } label: { SessionRow(item: item) }
                                        .swipeActions {
                                            Button(role: .destructive) { pendingDelete = item } label: {
                                                Label("Supprimer", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .animation(.snappy, value: model.sessions.map(\.id))
                }
            }
            .navigationTitle("Nuits")
            .refreshable { model.refresh() }
            .confirmationDialog("Supprimer cet enregistrement de l'iPhone ?",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { item in
                Button("Supprimer", role: .destructive) {
                    withAnimation(.snappy) { model.delete(item) }
                }
                Button("Annuler", role: .cancel) {}
            } message: { _ in
                Text("Il n'existe aucune autre copie, sauf si tu l'as partagé.")
            }
        }
    }
}

struct SessionRow: View {
    let item: SessionItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isNight ? "moon.fill" : "list.number")
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background((item.isNight ? Color.indigo : Color.teal).gradient,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    if let summary = item.summary {
                        Text(TimeText.duration(summary.duration))
                        if !summary.endedNormally {
                            Text("interrompu").foregroundStyle(.orange)
                        }
                    } else {
                        Text(item.kindLabel)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let summary = item.summary {
                ProgressRing(progress: summary.sensorCoverage, lineWidth: 4,
                             tint: summary.sensorCoverage >= 0.98 ? .green : .orange)
                    .frame(width: 26, height: 26)
                    .accessibilityLabel("Capteurs enregistrés \(summary.sensorCoverage.percentText)")
            }
        }
        .padding(.vertical, 2)
    }
}

/// Bilan d'une séance : ce qui a été enregistré, ce qui a été perdu et quand.
struct SessionDetailView: View {
    let item: SessionItem

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var sizeText = "…"
    @State private var sharedFile: SharedFile?
    @State private var zipping = false
    @State private var confirmDelete = false
    @State private var alert: AlertMessage?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let summary = item.summary {
                    header(summary)
                    timelineCard(summary)
                    coverageCard(summary)
                    measuresCard(summary)
                } else {
                    Text("Pas encore de bilan pour cet enregistrement (il est peut-être en cours).")
                        .card()
                }
                Text("L'analyse complète de la nuit (pouls, respiration, positions, ronflements) arrive dans une "
                     + "prochaine version de l'app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(item.kindLabel)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let url = item.url
            let bytes = await Task.detached { SessionStore.size(of: url) }.value
            sizeText = String(format: "%.0f Mo", Double(bytes) / 1_000_000)
        }
        .sheet(item: $sharedFile) { ShareSheet(items: [$0.url]) }
        .alert(item: $alert) { Alert(title: Text($0.title), message: Text($0.message)) }
        .confirmationDialog("Supprimer cet enregistrement de l'iPhone ?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                model.delete(item)
                dismiss()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Il n'existe aucune autre copie, sauf si tu l'as partagé.")
        }
    }

    private func header(_ summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title).font(.subheadline).foregroundStyle(.secondary)
            Text(TimeText.duration(summary.duration))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 6) {
                Image(systemName: "bed.double.fill").foregroundStyle(.indigo)
                Text("\(TimeText.hourMinute(summary.startUnix)) → \(TimeText.hourMinute(summary.endUnix))")
            }
            .font(.subheadline)
            Label {
                Text(summary.endExplanation).font(.footnote)
            } icon: {
                Image(systemName: summary.endedNormally ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.endedNormally ? .green : .orange)
            }
            if let delayed = item.info?.delayedStart {
                Text("Début différé de \(delayed.delayMinutes) min (« Oui » à \(TimeText.hourMinute(delayed.requestedUnix)))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    /// Frise de la séance : en vert ce qui est enregistré, en rouge les passages perdus.
    private func timelineCard(_ summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Déroulé").font(.subheadline.weight(.semibold))
            GeometryReader { geometry in
                let width = geometry.size.width
                let span = max(1, summary.endUnix - summary.startUnix)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.green.opacity(0.75))
                    ForEach(Array(summary.losses.enumerated()), id: \.offset) { _, loss in
                        let x = CGFloat((loss.startUnix - summary.startUnix) / span) * width
                        let w = max(3, CGFloat(loss.duration / span) * width)
                        Rectangle()
                            .fill(loss.what == "son" ? Color.orange : Color.red)
                            .frame(width: w)
                            .offset(x: min(max(0, x), width - w))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            HStack {
                Text(TimeText.hourMinute(summary.startUnix))
                Spacer()
                Text(TimeText.hourMinute(summary.endUnix))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if summary.losses.isEmpty {
                Label("Aucun passage perdu", systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            } else {
                ForEach(Array(summary.losses.enumerated()), id: \.offset) { _, loss in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(TimeText.hourMinute(loss.startUnix)) — \(TimeText.duration(loss.duration)) sans \(Self.whatText(loss.what))")
                            .font(.footnote.weight(.semibold))
                        Text(loss.cause).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card()
    }

    private func coverageCard(_ summary: SessionSummary) -> some View {
        HStack(spacing: 12) {
            coverageRing(title: "Capteurs", value: summary.sensorCoverage, icon: "waveform.path.ecg")
            coverageRing(title: "Son", value: summary.audioCoverage, icon: "mic.fill")
            VStack(spacing: 6) {
                Text("\(summary.interruptions)")
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                Text("interruptions").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .card()
    }

    private func coverageRing(title: String, value: Double, icon: String) -> some View {
        VStack(spacing: 8) {
            ZStack {
                ProgressRing(progress: value, lineWidth: 7, tint: value >= 0.98 ? .green : .orange)
                Text(value.percentText).font(.caption.weight(.semibold)).monospacedDigit()
            }
            .frame(width: 64, height: 64)
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func measuresCard(_ summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mesures").font(.subheadline.weight(.semibold))
            ForEach(summary.measuredRates.keys.sorted(), id: \.self) { stream in
                InfoRow(label: "Fréquence · \(RecordingView.streamLabel(stream))",
                        value: String(format: "%.1f Hz", summary.measuredRates[stream] ?? 0))
            }
            if let start = summary.batteryStart, let end = summary.batteryEnd {
                InfoRow(label: "Batterie", value: "\(start.percentText) → \(end.percentText)")
            }
            if let drain = summary.batteryDrainPerHour {
                InfoRow(label: "Consommation", value: String(format: "%.1f %% par heure", drain * 100))
            }
            if let calibration = item.info?.calibration {
                InfoRow(label: "Calibration", value: Self.calibrationText(calibration, mode: item.info?.calibrationMode),
                        valueColor: calibration.isPlausible ? .primary : .orange)
            }
            InfoRow(label: "Taille", value: sizeText)
        }
        .font(.subheadline)
        .card()
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                makeZip()
            } label: {
                HStack {
                    if zipping { ProgressView().tint(.white) } else { Image(systemName: "square.and.arrow.up") }
                    Text(zipping ? "Préparation…" : "Partager l'enregistrement (.zip)")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .prominentButton()
            .disabled(zipping)
            Text("Pour le garder ailleurs (Fichiers, iCloud Drive) ou me l'envoyer. Les enregistrements sont aussi "
                 + "dans l'app Fichiers, « Sur mon iPhone › Sommeil ».")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Supprimer de l'iPhone", systemImage: "trash")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .secondaryButton()
            .padding(.top, 6)
        }
    }

    static func calibrationText(_ calibration: Calibration, mode: String?) -> String {
        let automatic = mode == "automatique"
        if calibration.isPlausible { return automatic ? "automatique, réussie" : "réussie" }
        if calibration.tiltDegrees > Calibration.maxPlausibleTilt {
            return automatic ? "automatique : aucun moment calme sur le dos" : "téléphone incliné (pas sur le dos ?)"
        }
        return automatic ? "automatique : tu bougeais" : "tu as bougé"
    }

    private func makeZip() {
        zipping = true
        let url = item.url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SessionStore.makeZip(of: url) }
            DispatchQueue.main.async {
                zipping = false
                switch result {
                case .success(let zip): sharedFile = SharedFile(url: zip)
                case .failure(let error): alert = AlertMessage(title: "Export impossible", message: error.localizedDescription)
                }
            }
        }
    }

    static func whatText(_ what: String) -> String {
        switch what {
        case "capteurs": return "capteurs"
        case "son": return "son"
        default: return "aucun enregistrement"
        }
    }
}
