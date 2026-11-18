// Diagnostic temporaire : les graphiques du rapport plantent-ils avec les valeurs de la version 0.4 ?
// Chaque cas tourne dans son propre processus (un plantage n'empêche pas les autres).
import SwiftUI
import Charts

struct P: Identifiable { var id: Int; var x: Double; var y: Double; var s: String }

@MainActor
func render<V: View>(_ view: V) {
    let renderer = ImageRenderer(content: view.frame(width: 400, height: 120))
    renderer.scale = 1
    let image = renderer.cgImage
    print("rendu :", image.map { "\($0.width)x\($0.height)" } ?? "aucune image")
}

func points(_ labels: [String]) -> [P] {
    (0..<60).map { P(id: $0, x: Double($0), y: 14 + Double($0 % 3), s: labels[$0 % labels.count]) }
}

@main
struct Main {
    @MainActor
    static func main() {
        let c = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "1"
        print("cas", c)
        switch c {
        case "1": // témoin : toutes les valeurs dans l'échelle (rapport 0.3)
            render(Chart(points(["mouvement", "son"])) { p in
                PointMark(x: .value("t", p.x), y: .value("r", p.y)).foregroundStyle(by: .value("Source", p.s))
            }.chartForegroundStyleScale(["mouvement": Color.teal, "son": Color.blue]))
        case "2": // rapport 0.4 : « mouvement+son » absent de l'échelle
            render(Chart(points(["mouvement+son", "mouvement", "son"])) { p in
                PointMark(x: .value("t", p.x), y: .value("r", p.y)).foregroundStyle(by: .value("Source", p.s))
            }.chartForegroundStyleScale(["mouvement": Color.teal, "son": Color.blue]))
        case "3": // seulement des valeurs absentes de l'échelle
            render(Chart(points(["mouvement+son"])) { p in
                PointMark(x: .value("t", p.x), y: .value("r", p.y)).foregroundStyle(by: .value("Source", p.s))
            }.chartForegroundStyleScale(["mouvement": Color.teal, "son": Color.blue]))
        case "4": // position « Inconnue » absente de l'échelle
            render(Chart(points(["Dos", "Inconnue"])) { p in
                RectangleMark(xStart: .value("a", p.x), xEnd: .value("b", p.x + 1), yStart: .value("", 0), yEnd: .value("", 1))
                    .foregroundStyle(by: .value("Position", p.s))
            }.chartForegroundStyleScale(["Dos": Color.indigo, "Côté gauche": Color.teal, "Côté droit": Color.mint,
                                         "Ventre": Color.purple, "Assis ou debout": Color.orange]))
        case "5": // même cas que 2 avec domain/range
            render(Chart(points(["mouvement+son", "mouvement", "son"])) { p in
                PointMark(x: .value("t", p.x), y: .value("r", p.y)).foregroundStyle(by: .value("Source", p.s))
            }.chartForegroundStyleScale(domain: ["mouvement", "son"], range: [Color.teal, Color.blue]))
        default:
            print("cas inconnu")
        }
        print("fin normale")
    }
}
