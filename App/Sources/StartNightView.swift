import SwiftUI
import SleepCore

/// Feuille « Démarrer la nuit ? » : une barre de 0 à 2 h, puis Oui / Non.
/// Ouverte par « Commencer la nuit » ou depuis la notification du soir.
struct StartNightSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let request: StartSheetRequest
    @State private var minutes: Double

    init(request: StartSheetRequest) {
        self.request = request
        _minutes = State(initialValue: Double(request.minutes))
    }

    var body: some View {
        let chosen = NightDelay.clamp(minutes)
        ScrollView {
            VStack(spacing: 16) {
                Text("Démarrer la nuit ?")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 20)
                VStack(spacing: 4) {
                    Text(Self.capitalized(NightDelay.text(chosen)))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if chosen > 0 {
                        Text("Début vers \(Date().addingTimeInterval(Double(chosen) * 60).formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
                Slider(value: $minutes, in: 0...Double(NightDelay.maxMinutes), step: Double(NightDelay.stepMinutes)) {
                    Text("Délai avant le début de l'enregistrement")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("2 h")
                }
                .sensoryFeedback(.selection, trigger: chosen)
                Text(Self.explanation(chosen))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(request.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Non").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        model.queueStart(minutes: chosen, source: request.source)
                        dismiss()
                    } label: {
                        Text(chosen == 0 ? "Oui, maintenant" : "Oui, \(NightDelay.text(chosen))")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .font(.headline)
                Text(Texts.charging)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    static func explanation(_ minutes: Int) -> String {
        if minutes == 0 {
            return "L'enregistrement commence tout de suite : allonge-toi sur le dos et ne bouge plus pendant "
                + "30 secondes (calibration). Ensuite, verrouille l'écran."
        }
        return "Attache le téléphone et verrouille l'écran. L'app attend en silence (rien n'est enregistré), "
            + "puis enregistre jusqu'à ce que tu touches « Arrêter ». Pas de voix : la calibration se fait toute "
            + "seule, pendant un moment calme sur le dos. Si tu t'endors avant le début, ton endormissement "
            + "ne sera pas mesuré."
    }
}
