import SwiftUI

/// Couleurs d'un graphique, construites à partir des valeurs réellement affichées.
///
/// Swift Charts arrête l'app (« Trace/BPT trap ») si une valeur passée à `foregroundStyle(by:)` manque dans
/// `chartForegroundStyleScale`. C'est ce qui faisait planter le rapport de la 0.4 : la respiration « mouvement+son »
/// n'était pas dans l'échelle. Ici, chaque valeur présente a toujours une couleur (`other` pour les inconnues),
/// et la légende ne montre que les valeurs présentes.
struct ChartPalette {
    let domain: [String]
    let range: [Color]

    init(_ values: [String], known: KeyValuePairs<String, Color>, other: Color = .gray) {
        let present = Set(values)
        var domain: [String] = []
        var range: [Color] = []
        for (label, color) in known where present.contains(label) {
            domain.append(label)
            range.append(color)
        }
        for label in values where !domain.contains(label) {
            domain.append(label)
            range.append(other)
        }
        if domain.isEmpty {
            // Aucune donnée colorée : une échelle complète, sans risque puisqu'aucune valeur ne la consulte.
            for (label, color) in known {
                domain.append(label)
                range.append(color)
            }
        }
        self.domain = domain
        self.range = range
    }
}

extension View {
    /// Applique une `ChartPalette` (à utiliser à la place de `chartForegroundStyleScale` avec une liste fixe).
    func chartPalette(_ palette: ChartPalette) -> some View {
        chartForegroundStyleScale(domain: palette.domain, range: palette.range)
    }
}
