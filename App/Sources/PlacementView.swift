import SwiftUI
import SleepCore

/// Écran « test de placement » : qualité des battements et de la respiration en direct,
/// pour trouver le meilleur endroit et le bon serrage de la bande. Rien n'est enregistré.
struct PlacementView: View {
    @EnvironmentObject private var recorder: Recorder

    struct Note: Identifiable {
        let id = UUID()
        let place: String
        let heart: Double
        let breath: Double
        let bpm: Double?
    }

    static let places = ["Bas du sternum", "Milieu du sternum", "Sur le cœur (à gauche)", "Sous les côtes", "Autre"]

    @State private var snapshot = LiveAnalyzer.Snapshot()
    @State private var history: [LiveAnalyzer.Snapshot] = []
    @State private var notes: [Note] = []
    @State private var place = PlacementView.places[0]

    var body: some View {
        List {
            Section {
                Text("Attache le téléphone, allonge-toi sur le dos et ne bouge plus. Les mesures se stabilisent "
                     + "en 10 à 20 secondes. Essaie plusieurs endroits et plusieurs serrages, puis note chacun.")
                    .font(.footnote)
            }
            Section("Battements du cœur") {
                heartContent(snapshot)
            }
            Section("Respiration") {
                breathContent(snapshot)
            }
            Section {
                Picker("Emplacement", selection: $place) {
                    ForEach(Self.places, id: \.self) { Text($0) }
                }
                Button("Noter cet emplacement (moyenne des 15 dernières secondes)") { addNote() }
                    .disabled(history.count < 5)
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.place).font(.subheadline.weight(.semibold))
                        Text("Cœur \(Int(note.heart * 100))/100 · respiration \(Int(note.breath * 100))/100"
                             + (note.bpm.map { String(format: " · %.0f bpm", $0) } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Comparer les emplacements")
            } footer: {
                Text("Garde l'emplacement et le serrage avec la meilleure note « cœur », tant que la respiration "
                     + "reste au-dessus de 50. Ces notes sont aussi écrites dans le journal de diagnostic.")
            }
        }
        .navigationTitle("Test de placement")
        .onAppear { recorder.startPlacement() }
        .onDisappear { recorder.stopPlacement() }
        .onReceive(recorder.analyzer.$snapshot) { value in
            snapshot = value
            guard value.secondsBuffered >= 6 else { return }
            history.append(value)
            if history.count > 15 { history.removeFirst(history.count - 15) }
        }
    }

    @ViewBuilder
    private func heartContent(_ snapshot: LiveAnalyzer.Snapshot) -> some View {
        if snapshot.secondsBuffered < 6 {
            HStack { ProgressView(); Text("Mesure en cours…") }
        } else {
            if snapshot.movement >= MovementLevel.movingThreshold {
                Label("Tu bouges : reste immobile quelques secondes.", systemImage: "figure.walk")
                    .foregroundStyle(.orange)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.heart.bpm.map { snapshot.heart.quality >= 0.3 ? String(format: "%.0f", $0) : "—" } ?? "—")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("bpm").foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Qualité \(Int(snapshot.heart.quality * 100))/100").font(.subheadline)
                    Text(snapshot.heart.channel).font(.caption).foregroundStyle(.secondary)
                }
            }
            QualityBar(value: snapshot.heart.quality)
            WaveformView(samples: snapshot.waveform, beats: snapshot.beats).frame(height: 90)
            Text(heartAdvice(snapshot)).font(.footnote)
            DisclosureGroup("Détail par axe") {
                ForEach(snapshot.channels, id: \.channel) { channel in
                    HStack {
                        Text(channel.channel).frame(width: 70, alignment: .leading)
                        QualityBar(value: channel.quality, height: 8)
                        Text(channel.bpm.map { String(format: "%.0f", $0) } ?? "—")
                            .frame(width: 36, alignment: .trailing).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func breathContent(_ snapshot: LiveAnalyzer.Snapshot) -> some View {
        if snapshot.secondsBuffered < 20 {
            HStack { ProgressView(); Text("Il faut 20 secondes de mesure…") }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.breath.perMinute.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                Text("par minute").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "amplitude %.1f°", snapshot.breath.amplitudeDegrees)).font(.subheadline)
            }
            QualityBar(value: snapshot.breath.quality)
            Text(snapshot.breath.quality >= 0.5
                 ? "Respiration bien visible."
                 : "Respiration peu nette : respire normalement, sans bouger, et vérifie que la bande tient bien.")
                .font(.footnote)
        }
    }

    private func heartAdvice(_ snapshot: LiveAnalyzer.Snapshot) -> String {
        let q = snapshot.heart.quality
        if q >= 0.5 { return "Très bien : les battements sont nets." }
        if q >= 0.3 { return "Battements visibles mais faibles. Essaie de serrer un peu plus, ou de déplacer le téléphone." }
        return "Battements peu visibles. Serre davantage la bande, ou essaie le bas du sternum."
    }

    private func addNote() {
        guard !history.isEmpty else { return }
        let heart = history.map(\.heart.quality).reduce(0, +) / Double(history.count)
        let breath = history.map(\.breath.quality).reduce(0, +) / Double(history.count)
        let rates = history.compactMap { $0.heart.quality >= 0.3 ? $0.heart.bpm : nil }
        let bpm = rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count)
        let note = Note(place: place, heart: heart, breath: breath, bpm: bpm)
        notes.insert(note, at: 0)
        Diagnostics.shared.log(String(format: "Placement noté : %@ — cœur %.2f, respiration %.2f, %@", place, heart, breath,
                                      bpm.map { String(format: "%.0f bpm", $0) } ?? "pouls ?"))
    }
}
