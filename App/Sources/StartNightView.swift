import SwiftUI
import SleepCore

/// Feuille « Démarrer la nuit ? » : une barre de 0 à 2 h, puis Oui / Non.
/// Ouverte par « Commencer la nuit » ou depuis la notification du soir.
struct StartNightSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
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
            VStack(spacing: 18) {
                Image(systemName: chosen == 0 ? "moon.zzz.fill" : "timer")
                    .font(.system(size: 40))
                    .foregroundStyle(.indigo)
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.top, 24)
                Text("Démarrer la nuit ?")
                    .font(.title2.weight(.bold))
                VStack(spacing: 4) {
                    Text(Self.capitalized(NightDelay.text(chosen)))
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(chosen)))
                        .animation(.snappy, value: chosen)
                    Text(chosen > 0 ? "Début vers \(clockText(Date().addingTimeInterval(Double(chosen) * 60)))"
                                    : "Calibration de 30 secondes, puis bonne nuit")
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                Slider(value: $minutes, in: 0...Double(NightDelay.maxMinutes), step: Double(NightDelay.stepMinutes)) {
                    Text("Délai avant le début de l'enregistrement")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("2 h")
                }
                .tint(.indigo)
                .sensoryFeedback(.selection, trigger: chosen)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Où sera le téléphone ?").font(.subheadline.weight(.semibold))
                    Picker("Emplacement du téléphone", selection: $settings.placement) {
                        Text("À côté de la tête").tag("a_cote")
                        Text("Sur la poitrine").tag("corps")
                    }
                    .pickerStyle(.segmented)
                    Text(settings.placement == "corps"
                         ? "Pouls battement par battement, position du corps, respiration par le mouvement. Moins confortable."
                         : "Confortable. Respiration et ronflements au micro, pouls moyen sur 5 min. Pose-le à plat, calé, "
                           + "près de l'oreiller, sans le couvrir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.snappy, value: settings.placement)
                Text(Self.explanation(chosen, placement: settings.placement))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(request.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Non").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .secondaryButton()
                    Button {
                        model.queueStart(minutes: chosen, source: request.source)
                        dismiss()
                    } label: {
                        Text(chosen == 0 ? "Oui, maintenant" : "Oui, \(NightDelay.text(chosen))")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .prominentButton()
                    .tint(.indigo)
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

    static func explanation(_ minutes: Int, placement: String) -> String {
        if minutes == 0 {
            return placement == "corps"
                ? "L'enregistrement commence tout de suite : allonge-toi sur le dos et ne bouge plus pendant "
                  + "30 secondes (calibration). Ensuite, verrouille l'écran."
                : "L'enregistrement commence tout de suite : pose le téléphone et ne le touche plus pendant "
                  + "30 secondes. Ensuite, tu peux verrouiller l'écran."
        }
        return "Verrouille l'écran. L'app attend en silence (rien n'est enregistré), puis enregistre jusqu'à ce que "
            + "tu l'arrêtes. Pas de voix : la calibration se fait toute seule, pendant un moment calme sur le dos. "
            + "Si tu t'endors avant le début, ton endormissement ne sera pas mesuré."
    }
}
