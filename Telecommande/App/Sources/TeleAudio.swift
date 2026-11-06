import AVFoundation
import os

/// Tampon circulaire stéréo (échantillons entrelacés G, D) entre le réseau et le haut-parleur.
/// Un verrou très court protège lecture et écriture.
final class TeleRing {
    private let capacite: Int            // en trames (1 trame = G + D)
    private let donnees: UnsafeMutablePointer<Float>
    private var lecture = 0
    private var ecriture = 0
    private(set) var compte = 0          // trames en attente
    private let verrou: os_unfair_lock_t = {
        let p = os_unfair_lock_t.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()
    private var amorcage = true          // on attend d'avoir `cible` trames avant de jouer
    var cible: Int                       // latence visée, en trames
    var coupures = 0                     // nombre de fois où le tampon s'est vidé

    init(capacite: Int, cible: Int) {
        self.capacite = capacite
        self.cible = cible
        donnees = .allocate(capacity: capacite * 2)
        donnees.initialize(repeating: 0, count: capacite * 2)
    }

    deinit {
        donnees.deallocate()
        verrou.deallocate()
    }

    func vider() {
        os_unfair_lock_lock(verrou)
        lecture = 0; ecriture = 0; compte = 0; amorcage = true
        os_unfair_lock_unlock(verrou)
    }

    /// Ajoute des trames int16 stéréo entrelacées (format envoyé par le PC).
    func ecrire(_ data: Data) {
        let n = data.count / 4
        guard n > 0 else { return }
        os_unfair_lock_lock(verrou)
        data.withUnsafeBytes { brut in
            let s = brut.bindMemory(to: Int16.self)
            for i in 0..<n {
                let j = ecriture * 2
                donnees[j] = Float(Int16(littleEndian: s[2 * i])) / 32768
                donnees[j + 1] = Float(Int16(littleEndian: s[2 * i + 1])) / 32768
                ecriture = (ecriture + 1) % capacite
            }
        }
        compte += n
        // Trop d'avance (le réseau a envoyé une rafale) : on saute pour revenir à la latence visée.
        let maximum = min(capacite - 1, cible + 4800)
        if compte > maximum {
            let saut = compte - cible
            lecture = (lecture + saut) % capacite
            compte -= saut
        }
        os_unfair_lock_unlock(verrou)
    }

    /// Remplit les deux canaux pour le haut-parleur (appelé sur le fil audio).
    func lire(gauche: UnsafeMutablePointer<Float>, droite: UnsafeMutablePointer<Float>, n: Int, gain: Float) {
        os_unfair_lock_lock(verrou)
        if amorcage && compte >= cible { amorcage = false }
        var lu = 0
        if !amorcage {
            lu = min(n, compte)
            for i in 0..<lu {
                let j = lecture * 2
                gauche[i] = donnees[j] * gain
                droite[i] = donnees[j + 1] * gain
                lecture = (lecture + 1) % capacite
            }
            compte -= lu
            if lu < n {          // le réseau n'a pas suivi : silence et on se ré-amorce
                amorcage = true
                coupures += 1
            }
        }
        os_unfair_lock_unlock(verrou)
        for i in lu..<n { gauche[i] = 0; droite[i] = 0 }
    }
}

/// Reçoit le son du PC (WebSocket /audio) et le joue sur le téléphone.
final class TeleAudio {
    static let taux = 48_000.0
    private var engine: AVAudioEngine?
    private var tache: URLSessionWebSocketTask?
    private let ring = TeleRing(capacite: 48_000, cible: 4_800)
    private var actif = false
    var gain: Float = 1

    /// Latence visée en millisecondes (plus bas = plus réactif, plus haut = moins de coupures).
    var latenceMs: Double = 100 {
        didSet { ring.cible = Int(Self.taux * latenceMs / 1000) }
    }

    var enAttenteMs: Double { Double(ring.compte) / Self.taux * 1000 }
    var coupures: Int { ring.coupures }
    var enMarche: Bool { actif }

    func demarrer(url: URL) throws {
        arreter()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        ring.cible = Int(Self.taux * latenceMs / 1000)
        ring.vider()
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.taux, channels: 2) else { return }
        let ring = self.ring
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(bufferList)
            guard abl.count >= 2,
                  let g = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let d = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.lire(gauche: g, droite: d, n: Int(frameCount), gain: self?.gain ?? 1)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        self.engine = engine

        let tache = URLSession.shared.webSocketTask(with: url)
        tache.maximumMessageSize = 1 << 20
        self.tache = tache
        actif = true
        tache.resume()
        recevoir(tache)
    }

    private func recevoir(_ tache: URLSessionWebSocketTask) {
        tache.receive { [weak self] resultat in
            guard let self, self.actif, tache === self.tache else { return }
            switch resultat {
            case .success(.data(let data)):
                self.ring.ecrire(data)
                self.recevoir(tache)
            case .success:
                self.recevoir(tache)
            case .failure:
                // coupure réseau : on réessaie dans une seconde tant que le son est demandé
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.actif, tache === self.tache, let url = tache.originalRequest?.url else { return }
                    let nouvelle = URLSession.shared.webSocketTask(with: url)
                    nouvelle.maximumMessageSize = 1 << 20
                    self.tache = nouvelle
                    self.ring.vider()
                    nouvelle.resume()
                    self.recevoir(nouvelle)
                }
            }
        }
    }

    func arreter() {
        actif = false
        tache?.cancel(with: .goingAway, reason: nil)
        tache = nil
        engine?.stop()
        engine = nil
        ring.vider()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
