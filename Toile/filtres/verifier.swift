// Compile les règles du bloqueur de Toile avec le vrai WebKit (sur le Mac de GitHub) et note celles
// qu'il refuse : une seule règle refusée empêcherait toute sa liste de fonctionner sur l'iPhone.
//
//     swiftc -O -o verifier Toile/filtres/verifier.swift
//     ./verifier <dossier>          (écrit <dossier>/rejets.json)
//     python3 Toile/filtres/convertir.py --retirer <dossier>
//
// rejets.json : { "reseau-1": [12, 40512], ... } (positions des règles refusées dans chaque fichier).
import Foundation
import WebKit

guard CommandLine.arguments.count == 2 else {
    print("Usage : verifier <dossier>")
    exit(1)
}
let dossier = URL(fileURLWithPath: CommandLine.arguments[1])
let magasin: WKContentRuleListStore = WKContentRuleListStore.default()
var compteur = 0

/// Attend un rappel de WebKit (appelé sur le fil principal).
func attendre(_ fini: () -> Bool) {
    while !fini() {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
    }
}

/// Compile une liste de règles ; renvoie l'erreur de WebKit, ou nil.
func compiler(_ regles: [Any]) -> String? {
    guard let donnees = try? JSONSerialization.data(withJSONObject: regles),
          let texte = String(data: donnees, encoding: .utf8) else { return "JSON illisible" }
    compteur += 1
    let identifiant = "verification-\(compteur)"
    var fini = false
    var erreur: String?
    magasin.compileContentRuleList(forIdentifier: identifiant, encodedContentRuleList: texte) { _, e in
        erreur = e.map { String(describing: $0) }
        fini = true
    }
    attendre { fini }
    var retire = false
    magasin.removeContentRuleList(forIdentifier: identifiant) { _ in retire = true }
    attendre { retire }
    return erreur
}

/// Positions des règles refusées (recherche par moitiés).
func refusees(_ regles: [Any], depart: Int) -> [Int] {
    guard !regles.isEmpty, let erreur = compiler(regles) else { return [] }
    if regles.count == 1 {
        let texte = (try? JSONSerialization.data(withJSONObject: regles[0])).flatMap { String(data: $0, encoding: .utf8) }
        print("  règle \(depart) refusée : \(erreur)\n    \(texte?.prefix(300) ?? "?")")
        return [depart]
    }
    let milieu = regles.count / 2
    return refusees(Array(regles[..<milieu]), depart: depart)
        + refusees(Array(regles[milieu...]), depart: depart + milieu)
}

let noms = ((try? FileManager.default.contentsOfDirectory(atPath: dossier.path)) ?? [])
    .filter { $0.hasSuffix(".json") && $0 != "manifeste.json" && $0 != "rejets.json" }
    .sorted()
var rejets: [String: [Int]] = [:]
for nom in noms {
    let url = dossier.appendingPathComponent(nom)
    guard let donnees = try? Data(contentsOf: url),
          let regles = try? JSONSerialization.jsonObject(with: donnees) as? [Any] else {
        print("\(nom) : illisible")
        exit(1)
    }
    let debut = Date()
    let mauvaises = refusees(regles, depart: 0)
    let duree = Date().timeIntervalSince(debut)
    let cle = String(nom.dropLast(".json".count))
    rejets[cle] = mauvaises
    print(String(format: "%@ : %d règles, %d refusée(s), %.1f s", nom, regles.count, mauvaises.count, duree))
}
let sortie = try JSONSerialization.data(withJSONObject: rejets, options: [.sortedKeys])
try sortie.write(to: dossier.appendingPathComponent("rejets.json"))
print("Rejets écrits : \(dossier.appendingPathComponent("rejets.json").path)")
