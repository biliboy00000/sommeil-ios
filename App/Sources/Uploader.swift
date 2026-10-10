import Foundation
import UIKit
import SleepCore

/// Envoi d'une séance au récepteur du PC (5_RECEVOIR_IPHONE.bat), sur le Wi-Fi de la maison.
///
/// Protocole (HTTP simple, voir pc/recevoir_iphone.py) :
/// - GET  /v2/ping                    → le PC répond qu'il est prêt
/// - GET  /v2/seance/<id>             → liste des fichiers déjà reçus et leur taille
/// - PUT  /v2/seance/<id>/<chemin>    → envoi d'un fichier
/// - POST /v2/seance/<id>/fin         → le PC vérifie et range la séance
/// Les fichiers déjà reçus en entier ne sont pas renvoyés : un envoi coupé reprend où il en était.
final class Uploader: ObservableObject {
    enum State: Equatable {
        case idle
        case running(progress: Double, text: String)
        case done(String)
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func state(for id: String) -> State { states[id] ?? .idle }

    /// Normalise l'adresse saisie : « 192.168.1.23 » → « http://192.168.1.23:8010 ».
    static func baseURL(from address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text), components.host != nil else { return nil }
        if components.port == nil { components.port = 8010 }
        components.path = ""
        return components.url
    }

    /// Vérifie que le récepteur du PC répond.
    func ping(address: String) async -> String {
        guard let base = Self.baseURL(from: address) else { return "Adresse invalide." }
        do {
            let (data, response) = try await session.data(from: base.appendingPathComponent("v2/ping"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return "Le PC répond, mais pas comme prévu." }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let name = json?["machine"] as? String ?? "le PC"
            return "Connexion réussie avec \(name)."
        } catch {
            return "Pas de réponse : \(Self.explain(error))"
        }
    }

    func upload(_ directory: URL, address: String, completion: (() -> Void)? = nil) {
        let id = directory.lastPathComponent
        if case .running = state(for: id) { return }
        states[id] = .running(progress: 0, text: "Connexion au PC…")
        Task {
            let task = await MainActor.run {
                UIApplication.shared.beginBackgroundTask(withName: "envoi-pc", expirationHandler: nil)
            }
            let result = await send(directory, address: address)
            await MainActor.run {
                states[id] = result
                if case .done = result {
                    let marker = ["unix": Clock.unix, "adresse": address] as [String: Any]
                    if let data = try? JSONSerialization.data(withJSONObject: marker) {
                        try? data.write(to: directory.appendingPathComponent(SessionStore.uploadedMarker))
                    }
                }
                Diagnostics.shared.log("Envoi de \(id) : \(result)")
                UIApplication.shared.endBackgroundTask(task)
                completion?()
            }
        }
    }

    private func send(_ directory: URL, address: String) async -> State {
        let id = directory.lastPathComponent
        guard let base = Self.baseURL(from: address) else {
            return .failed("Adresse du PC invalide. Vérifie-la dans les réglages.")
        }
        let sessionURL = base.appendingPathComponent("v2/seance").appendingPathComponent(id)

        // Ce que le PC a déjà.
        var received: [String: Int] = [:]
        do {
            let (data, response) = try await session.data(from: sessionURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .failed("Le PC ne répond pas comme prévu. As-tu lancé 5_RECEVOIR_IPHONE.bat ?")
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let files = json["fichiers"] as? [String: Int] {
                received = files
            }
        } catch {
            return .failed("PC introuvable : \(Self.explain(error))")
        }

        // Fichiers à envoyer : les données d'abord, les petits fichiers texte à la fin.
        let files = Self.files(in: directory)
        let toSend = files.filter { received[$0.relativePath] != $0.size }
        let totalBytes = max(1, toSend.reduce(0) { $0 + $1.size })
        var sentBytes = 0
        for (number, file) in toSend.enumerated() {
            let progress = Double(sentBytes) / Double(totalBytes)
            await MainActor.run {
                states[id] = .running(progress: progress, text: "Envoi \(number + 1)/\(toSend.count) : \(file.relativePath)")
            }
            var url = sessionURL
            for component in file.relativePath.split(separator: "/") { url.appendPathComponent(String(component)) }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            do {
                let (_, response) = try await session.upload(for: request, fromFile: file.url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return .failed("Le PC a refusé \(file.relativePath). Réessaie.")
                }
            } catch {
                return .failed("Envoi coupé (\(Self.explain(error))). Réessaie : l'envoi reprendra où il s'est arrêté.")
            }
            sentBytes += file.size
        }

        // Fin : le PC vérifie et range la séance.
        do {
            var request = URLRequest(url: sessionURL.appendingPathComponent("fin"))
            request.httpMethod = "POST"
            let manifest = Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0.size) })
            request.httpBody = try JSONSerialization.data(withJSONObject: ["fichiers": manifest])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = json?["message"] as? String ?? ""
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .failed("Le PC signale un problème : \(message)")
            }
            let megabytes = Double(files.reduce(0) { $0 + $1.size }) / 1_000_000
            return .done("Envoyé au PC (\(String(format: "%.0f", megabytes)) Mo). \(message)")
        } catch {
            return .failed("Dernière étape impossible : \(Self.explain(error))")
        }
    }

    struct LocalFile {
        let url: URL
        let relativePath: String
        let size: Int
    }

    static func files(in directory: URL) -> [LocalFile] {
        // Chemins relatifs fournis directement par le système (pas de souci de /private/var…).
        let manager = FileManager.default
        guard let paths = manager.subpaths(atPath: directory.path) else { return [] }
        var result: [LocalFile] = []
        for relative in paths {
            let components = relative.split(separator: "/")
            guard !components.contains(where: { $0.hasPrefix(".") }) else { continue }
            let url = directory.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            result.append(LocalFile(url: url, relativePath: relative, size: size))
        }
        let isText: (LocalFile) -> Bool = { $0.relativePath.hasSuffix(".json") || $0.relativePath.hasSuffix(".jsonl") }
        return result.filter { !isText($0) }.sorted { $0.relativePath < $1.relativePath }
            + result.filter(isText).sorted { $0.relativePath < $1.relativePath }
    }

    static func explain(_ error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case NSURLErrorTimedOut: return "délai dépassé. Le PC et l'iPhone sont-ils sur le même Wi-Fi ?"
        case NSURLErrorCannotConnectToHost: return "le PC refuse la connexion. 5_RECEVOIR_IPHONE.bat est-il lancé ?"
        case NSURLErrorNotConnectedToInternet: return "l'iPhone n'est pas connecté au Wi-Fi."
        case NSURLErrorCannotFindHost: return "adresse inconnue. Vérifie l'adresse dans les réglages."
        default: return error.localizedDescription
        }
    }
}
