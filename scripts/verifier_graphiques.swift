// Vérifie que les graphiques du rapport s'affichent avec toutes les valeurs que l'analyse peut produire.
// Swift Charts arrête l'app si une valeur de `foregroundStyle(by:)` manque dans l'échelle de couleurs
// (plantage de la 0.4.25 à l'ouverture du rapport). Compilé avec App/Sources/ChartPalette.swift.
// Usage : verifier_graphiques <cas>   (un cas par processus : un plantage n'empêche pas les autres)
import SwiftUI
import Charts

struct P: Identifiable { var id: Int; var x: Double; var y: Double; var s: String }

@MainActor
func render<V: View>(_ view: V) {
    let renderer = ImageRenderer(content: view.frame(width: 400, height: 120))
    renderer.scale = 1
    guard renderer.cgImage != nil else {
        print("aucune image")
        exit(2)
    }
}

func points(_ labels: [String]) -> [P] {
    labels.isEmpty ? [] : (0..<60).map { P(id: $0, x: Double($0), y: 14 + Double($0 % 3), s: labels[$0 % labels.count]) }
}

// Mêmes listes que TimelineCard (NightReportView.swift).
let breath: KeyValuePairs<String, Color> = ["Micro et capteurs": .indigo, "Capteurs": .teal, "Micro": .blue]
let positions: KeyValuePairs<String, Color> = ["Dos": .indigo, "Côté gauche": .teal, "Côté droit": .mint, "Ventre": .purple,
                                                "Assis ou debout": .orange, "Inconnue": .gray]
let levels: KeyValuePairs<String, Color> = ["Calme": .indigo, "Mouvements légers": .teal, "Éveil": .orange, "Agité": .orange,
                                             "Pas de mesure": Color.gray.opacity(0.3)]

@MainActor
func dots(_ labels: [String], _ known: KeyValuePairs<String, Color>) {
    let data = points(labels)
    render(Chart(data) { p in
        PointMark(x: .value("t", p.x), y: .value("r", p.y)).foregroundStyle(by: .value("Source", p.s))
    }.chartPalette(ChartPalette(data.map(\.s), known: known)))
}

@MainActor
func bands(_ labels: [String], _ known: KeyValuePairs<String, Color>) {
    let data = points(labels)
    render(Chart {
        ForEach(data) { p in
            RectangleMark(xStart: .value("a", p.x), xEnd: .value("b", p.x + 1), yStart: .value("", 0), yEnd: .value("", 1))
                .foregroundStyle(by: .value("Niveau", p.s))
        }
        RuleMark(x: .value("Pause", 20.0)).foregroundStyle(.red)
    }.chartPalette(ChartPalette(data.map(\.s), known: known)).chartYScale(domain: 0...1))
}

@main
struct Main {
    @MainActor
    static func main() {
        let c = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        switch c {
        case "respiration": dots(["Micro et capteurs", "Capteurs", "Micro"], breath)
        case "respiration-inconnue": dots(["Micro et capteurs", "Autre", "source jamais vue"], breath)
        case "positions": bands(["Dos", "Inconnue", "Ventre"], positions)
        case "niveaux-v2": bands(["Calme", "Mouvements légers", "Éveil", "Pas de mesure"], levels)
        case "niveaux-v1": bands(["Calme", "Agité", "Pas de mesure"], levels)
        case "niveaux-vides": bands([], levels)
        default:
            print("cas inconnu : \(c)")
            exit(1)
        }
        print("\(c) : affiché")
    }
}
