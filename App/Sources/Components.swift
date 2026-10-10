import SwiftUI
import UIKit
import SleepCore

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
        .accessibilityLabel("Qualité \(Int(value * 100)) sur 100")
    }
}

/// Courbe du signal filtré, avec les battements repérés.
struct WaveformView: View {
    let samples: [Double]
    let beats: [Double]

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            var path = Path()
            let step = size.width / CGFloat(samples.count - 1)
            for (i, value) in samples.enumerated() {
                let point = CGPoint(x: CGFloat(i) * step, y: size.height / 2 - CGFloat(value) * size.height * 0.45)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 1.2)
            for beat in beats {
                let x = CGFloat(beat) * size.width
                var marker = Path()
                marker.move(to: CGPoint(x: x, y: 0))
                marker.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(marker, with: .color(.red.opacity(0.5)), lineWidth: 2)
            }
        }
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
    static let charging = "Ne charge jamais le téléphone quand il est attaché sur toi sous la couette : "
        + "il chauffe. Charge-le avant de te coucher."
}
