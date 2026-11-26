import Foundation
import SwiftUI
import WebKit

/// Fichiers téléchargés depuis les pages, rangés dans « Sur mon iPhone › Toile › Téléchargements ».
@MainActor
final class Telechargements: NSObject, ObservableObject {
    static let shared = Telechargements()

    struct Element: Identifiable, Equatable {
        let id = UUID()
        var nom: String
        var fichier: URL?
        var progression: Double = 0
        var fini = false
        var erreur: String?
    }

    @Published private(set) var elements: [Element] = []
    /// Dernier téléchargement terminé (bandeau en haut de l'écran).
    @Published var annonce: Element?

    private var suivis: [ObjectIdentifier: UUID] = [:]
    private var observations: [UUID: NSKeyValueObservation] = [:]

    static var dossier: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Téléchargements", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private override init() {
        super.init()
    }

    func suivre(_ telechargement: WKDownload) {
        telechargement.delegate = self
    }

    private func modifier(_ id: UUID, _ changement: (inout Element) -> Void) {
        guard let i = elements.firstIndex(where: { $0.id == id }) else { return }
        changement(&elements[i])
    }

    private func terminer(_ telechargement: WKDownload, erreur: String?) {
        let cle = ObjectIdentifier(telechargement)
        guard let id = suivis.removeValue(forKey: cle) else { return }
        observations[id] = nil
        modifier(id) {
            $0.fini = erreur == nil
            $0.erreur = erreur
            $0.progression = 1
        }
        if erreur == nil, let element = elements.first(where: { $0.id == id }) {
            withAnimation { annonce = element }
        }
    }
}

extension Telechargements: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let dossier = Self.dossier
        var nom = suggestedFilename.replacingOccurrences(of: "/", with: "_").nettoye
        if nom.isEmpty { nom = "fichier" }
        var cible = dossier.appendingPathComponent(nom)
        let base = cible.deletingPathExtension().lastPathComponent
        let extensionFichier = cible.pathExtension
        var numero = 2
        while FileManager.default.fileExists(atPath: cible.path) {
            let essai = extensionFichier.isEmpty ? "\(base) \(numero)" : "\(base) \(numero).\(extensionFichier)"
            cible = dossier.appendingPathComponent(essai)
            numero += 1
        }
        let element = Element(nom: cible.lastPathComponent, fichier: cible)
        elements.insert(element, at: 0)
        suivis[ObjectIdentifier(download)] = element.id
        let id = element.id
        observations[id] = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progres, _ in
            let fraction = progres.fractionCompleted
            Task { @MainActor in self?.modifier(id) { $0.progression = fraction } }
        }
        completionHandler(cible)
    }

    func downloadDidFinish(_ download: WKDownload) {
        terminer(download, erreur: nil)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        terminer(download, erreur: error.localizedDescription)
    }
}
