import SwiftUI
import UIKit
import SleepCore

// Éléments d'interface partagés : cartes, anneaux, tuiles, bouton « maintenir pour arrêter »,
// et l'aspect « verre » d'iOS 26 quand il est disponible.

enum Palette {
    /// Bleu nuit du thème (dégradé de la carte « Ce soir » et de l'écran de nuit).
    static let nightTop = Color(red: 0.07, green: 0.07, blue: 0.20)
    static let nightBottom = Color(red: 0.20, green: 0.13, blue: 0.42)
    static let moon = Color(red: 1.0, green: 0.86, blue: 0.55)
    static let heart = Color(red: 1.0, green: 0.27, blue: 0.36)
    static let trace = Color(red: 0.25, green: 0.95, blue: 0.60)
    static let monitor = Color(red: 0.04, green: 0.05, blue: 0.07)
}

extension View {
    /// Carte arrondie sur le fond groupé de l'app.
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Pastille en verre (iOS 26), ou en matériau translucide avant.
    @ViewBuilder
    func glassPill(tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.35)) } ?? .regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Bouton principal : verre coloré (iOS 26), sinon bouton plein.
    @ViewBuilder
    func prominentButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func secondaryButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// Bouton qui s'enfonce légèrement quand on le touche (cartes et tuiles).
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Anneau de progression (0 à 1).
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 8
    var tint: Color = .accentColor
    var track: Color = Color.secondary.opacity(0.2)

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeInOut(duration: 0.5), value: progress)
    }
}

/// Petite tuile : icône, titre, valeur.
struct StatTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Bouton à maintenir enfoncé (évite d'arrêter la nuit par erreur, dans le noir).
struct HoldButton: View {
    let title: String
    var systemImage = "stop.fill"
    var tint: Color = .red
    var duration: Double = 1.2
    let action: () -> Void

    @State private var progress = 0.0
    @State private var pressing = false
    @State private var done = 0

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                ProgressRing(progress: progress, lineWidth: 3, tint: .white, track: .white.opacity(0.25))
                    .frame(width: 30, height: 30)
                Image(systemName: systemImage).font(.footnote.weight(.bold))
            }
            Text(pressing ? "Continue d'appuyer…" : title)
                .font(.headline)
                .contentTransition(.opacity)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(tint.opacity(pressing ? 0.95 : 0.8), in: Capsule())
        .scaleEffect(pressing ? 0.97 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pressing)
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 40) {
            done += 1
            progress = 0
            action()
        } onPressingChanged: { isPressing in
            pressing = isPressing
            withAnimation(isPressing ? .linear(duration: duration) : .easeOut(duration: 0.25)) {
                progress = isPressing ? 1 : 0
            }
        }
        .sensoryFeedback(.success, trigger: done)
        .sensoryFeedback(.impact(weight: .light), trigger: pressing) { _, new in new }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint("Maintiens le doigt appuyé")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

/// Ciel étoilé discret (positions fixes, scintillement lent).
struct Starfield: View {
    var count = 40
    var animated = true

    private struct Star { var x: Double; var y: Double; var size: Double; var phase: Double }

    private static func stars(_ count: Int) -> [Star] {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        return (0..<count).map { _ in Star(x: next(), y: next(), size: 0.6 + 1.6 * next(), phase: next() * 6.28) }
    }

    var body: some View {
        let stars = Self.stars(count)
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !animated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for star in stars {
                    let twinkle = animated ? 0.55 + 0.45 * sin(t * 0.8 + star.phase) : 0.8
                    let rect = CGRect(x: star.x * size.width, y: star.y * size.height, width: star.size, height: star.size)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.25 + 0.5 * twinkle)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Barre de qualité de 0 à 1, rouge → orange → vert.
struct QualityBar: View {
    let value: Double
    var height: CGFloat = 10

    var color: Color {
        if value >= 0.5 { return .green }
        if value >= 0.3 { return .orange }
        return .red
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color).frame(width: max(height, geometry.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.4), value: value)
        .accessibilityLabel("Qualité \(Int(value * 100)) sur 100")
    }
}

/// Feuille de partage iOS (AirDrop, Fichiers, Mail…).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// URL identifiable, pour afficher une feuille de partage.
struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Message d'alerte simple.
struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

extension Double {
    var percentText: String { "\(Int((self * 100).rounded())) %" }
}

/// Ligne « libellé : valeur ».
struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(valueColor).multilineTextAlignment(.trailing)
        }
    }
}

enum Texts {
    static let medical = "Ce n'est pas un appareil médical. Les mesures sont des estimations et les événements "
        + "respiratoires sont seulement « possibles ». Si des pauses reviennent souvent, ou si tu es très "
        + "fatigué la journée, parles-en à un médecin."
    static let charging = "Ne charge jamais le téléphone attaché sur toi ni sous la couette, l'oreiller ou le drap : "
        + "il chauffe. Charge-le avant de te coucher, ou à l'air libre sur la table de nuit."
    static let sideStoreRenewal = "Ouvre LocalDevVPN et touche « Connect », puis ouvre SideStore › My Apps › "
        + "« Refresh All ». Le compteur repart pour 7 jours. Un Raccourci peut le faire tout seul chaque jour."
}

/// Heure « 23:41 » (format de l'iPhone).
func clockText(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
}

/// Date « mardi 28 octobre » (avec majuscule).
func dayText(_ date: Date) -> String {
    let text = date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR")))
    return text.prefix(1).uppercased() + text.dropFirst()
}
