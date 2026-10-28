import Foundation

/// Lit le profil d'installation (« embedded.mobileprovision ») ajouté par SideStore (ou Sideloadly),
/// pour savoir quand l'app cessera de s'ouvrir.
public struct ProvisioningInfo: Equatable, Sendable {
    public var expiration: Date?
    public var creation: Date?
    public var name: String?
    public var teamName: String?

    /// Le fichier est une signature numérique qui contient un plist XML en clair.
    public static func parse(_ data: Data) -> ProvisioningInfo? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil),
              let dict = plist as? [String: Any]
        else { return nil }
        return ProvisioningInfo(expiration: dict["ExpirationDate"] as? Date,
                                creation: dict["CreationDate"] as? Date,
                                name: dict["Name"] as? String,
                                teamName: dict["TeamName"] as? String)
    }

    /// Jours restants avant expiration (peut être négatif).
    public func daysRemaining(now: Date = Date()) -> Double? {
        guard let expiration else { return nil }
        return expiration.timeIntervalSince(now) / 86_400
    }
}
