import Foundation
import SwiftUI

/// Fichiers de Toile (historique, favoris, onglets, filtres), dans « Application Support ».
enum Stockage {
    static var dossier: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toile", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func lire<T: Decodable>(_ type: T.Type, _ nom: String) -> T? {
        guard let donnees = try? Data(contentsOf: dossier.appendingPathComponent(nom)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: donnees)
    }

    static func ecrire<T: Encodable>(_ valeur: T, _ nom: String) {
        guard let donnees = try? JSONEncoder().encode(valeur) else { return }
        try? donnees.write(to: dossier.appendingPathComponent(nom), options: .atomic)
    }
}

struct Visite: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var titre: String
    var date: Date
}

struct Favori: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var titre: String
}

/// Pages visitées (onglets normaux seulement).
@MainActor
final class Historique: ObservableObject {
    static let shared = Historique()
    private static let maximum = 5000

    @Published private(set) var visites: [Visite]
    private var sauvegardePrevue = false

    private init() {
        visites = Stockage.lire([Visite].self, "historique.json") ?? []
    }

    func noter(_ url: URL, titre: String) {
        guard let schema = url.scheme?.lowercased(), schema == "http" || schema == "https" else { return }
        if let premiere = visites.first, premiere.url == url {
            if !titre.isEmpty { visites[0].titre = titre }
            visites[0].date = Date()
        } else {
            visites.insert(Visite(url: url, titre: titre, date: Date()), at: 0)
            if visites.count > Self.maximum {
                visites.removeLast(visites.count - Self.maximum)
            }
        }
        prevoirSauvegarde()
    }

    func supprimer(_ identifiants: Set<UUID>) {
        visites.removeAll { identifiants.contains($0.id) }
        prevoirSauvegarde()
    }

    func effacer() {
        visites.removeAll()
        sauvegarder()
    }

    func sauvegarder() {
        Stockage.ecrire(visites, "historique.json")
    }

    private func prevoirSauvegarde() {
        guard !sauvegardePrevue else { return }
        sauvegardePrevue = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            sauvegardePrevue = false
            sauvegarder()
        }
    }
}

@MainActor
final class Favoris: ObservableObject {
    static let shared = Favoris()

    @Published var liste: [Favori] {
        didSet { Stockage.ecrire(liste, "favoris.json") }
    }

    private init() {
        liste = Stockage.lire([Favori].self, "favoris.json") ?? [
            Favori(url: URL(string: "https://m.youtube.com/")!, titre: "YouTube"),
            Favori(url: URL(string: "https://www.google.com/")!, titre: "Google"),
            Favori(url: URL(string: "https://fr.wikipedia.org/")!, titre: "Wikipédia"),
        ]
    }

    func contient(_ url: URL?) -> Bool {
        guard let url else { return false }
        return liste.contains { $0.url == url }
    }

    func basculer(_ url: URL, titre: String) {
        if contient(url) {
            liste.removeAll { $0.url == url }
        } else {
            liste.append(Favori(url: url, titre: titre.isEmpty ? (url.host ?? url.absoluteString) : titre))
        }
    }
}
