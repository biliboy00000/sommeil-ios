import Foundation
import SleepCore

/// Commande du Blue Yeti branché au PC, à travers le récepteur (5_RECEVOIR_IPHONE.bat).
///
/// - POST /v2/yeti/demarrer  {"seance": id}  → le PC commence à enregistrer dans le dossier de la séance
/// - POST /v2/yeti/arreter   {"seance": id}  → le PC arrête (il arrête aussi tout seul à la réception de la séance)
/// - GET  /v2/yeti/etat                      → enregistre-t-il ? depuis combien de temps ? niveau sonore ?
/// Chaque demande porte le code du PC (en-tête X-Code-PC) et l'heure de l'iPhone (X-Unix),
/// ce qui permet au PC de mesurer l'écart entre les deux horloges.
enum PCLink {
    struct YetiState: Decodable, Equatable {
        var ok: Bool?
        var enregistre: Bool?
        var secondes: Double?
        var niveau_db: Double?
        var micro: String?
        var yeti: Bool?
        var erreur: String?
        var message: String?
    }

    enum Outcome: Equatable {
        case state(YetiState)
        case failure(String)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func start(sessionID: String, address: String, code: String) async -> Outcome {
        await call("demarrer", method: "POST", body: ["seance": sessionID], address: address, code: code)
    }

    static func stop(sessionID: String, address: String, code: String) async -> Outcome {
        await call("arreter", method: "POST", body: ["seance": sessionID], address: address, code: code)
    }

    static func status(address: String, code: String) async -> Outcome {
        await call("etat", method: "GET", body: nil, address: address, code: code)
    }

    private static func call(_ action: String, method: String, body: [String: String]?,
                             address: String, code: String) async -> Outcome {
        guard let base = Uploader.baseURL(from: address) else { return .failure("adresse du PC invalide") }
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else { return .failure("code du PC manquant (Réglages)") }
        var request = URLRequest(url: base.appendingPathComponent("v2/yeti").appendingPathComponent(action))
        request.httpMethod = method
        request.setValue(trimmedCode, forHTTPHeaderField: "X-Code-PC")
        request.setValue(String(format: "%.3f", Clock.unix), forHTTPHeaderField: "X-Unix")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let state = try? JSONDecoder().decode(YetiState.self, from: data)
            switch code {
            case 200: return state.map { .state($0) } ?? .failure("réponse du PC illisible")
            case 403: return .failure("code du PC incorrect (Réglages)")
            case 404: return .failure("le récepteur du PC est trop ancien : remplace ses fichiers")
            case 503: return .failure(state?.message ?? "enregistrement du Yeti indisponible sur le PC")
            default:
                if let state, state.erreur != nil { return .state(state) }
                return .failure(state?.message ?? "erreur du PC (\(code))")
            }
        } catch {
            return .failure("PC injoignable : \(Uploader.explain(error))")
        }
    }

    /// Phrase courte pour l'écran.
    static func describe(_ outcome: Outcome) -> (text: String, ok: Bool) {
        switch outcome {
        case .failure(let message):
            return (message.prefix(1).uppercased() + message.dropFirst(), false)
        case .state(let state):
            if state.enregistre == true {
                var text = "enregistre"
                if let seconds = state.secondes { text += " · " + TimeText.duration(seconds) }
                if let level = state.niveau_db { text += " · \(Int(level.rounded())) dB" }
                if state.yeti == false, let micro = state.micro { text += " · micro « \(micro) » (Yeti introuvable)" }
                return (text, state.yeti != false)
            }
            if let error = state.erreur { return ("n'enregistre pas : \(error)", false) }
            return ("arrêté", true)
        }
    }
}
