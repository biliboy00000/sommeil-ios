import Foundation
import CoreBluetooth
import SleepCore

/// Ceinture cardio Bluetooth (service standard « Heart Rate », par exemple Polar H10), enregistrée pendant la nuit
/// comme référence : elle sert à mesurer la vraie précision du pouls de l'app.
/// Chaque notification est écrite dans `ceinture.jsonl` (horloge des capteurs, pouls, intervalles RR).
final class ChestStrap: NSObject, ObservableObject {
    static let shared = ChestStrap()
    static let service = CBUUID(string: "180D")
    static let measurement = CBUUID(string: "2A37")

    struct Found: Identifiable, Equatable {
        let id: UUID
        let name: String
        var rssi: Int
    }

    @Published private(set) var found: [Found] = []
    @Published private(set) var scanning = false
    @Published private(set) var status = "Arrêtée"
    @Published private(set) var lastBPM: Int?
    @Published private(set) var savedName: String?
    @Published private(set) var bluetoothOff = false

    /// Événements à noter dans le journal de la séance.
    var onEvent: ((String) -> Void)?

    private let queue = DispatchQueue(label: "sommeil.ceinture")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writer: JSONLinesWriter?
    private var recording = false
    private var samples = 0
    /// Recherche demandée (lu sur la file Bluetooth, contrairement à `scanning`).
    private var wantsScan = false
    private let defaults = UserDefaults.standard

    private var savedID: UUID? {
        get { defaults.string(forKey: "strapID").flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: "strapID") }
    }

    override init() {
        super.init()
        savedName = defaults.string(forKey: "strapName")
    }

    private func ensureCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: queue)
    }

    private func publish(_ change: @escaping () -> Void) { DispatchQueue.main.async(execute: change) }

    // MARK: - Association

    func startScan() {
        ensureCentral()
        queue.async {
            self.wantsScan = true
            self.publish { self.found = []; self.scanning = true }
            guard self.central?.state == .poweredOn else { return }
            self.central?.scanForPeripherals(withServices: [Self.service])
        }
    }

    func stopScan() {
        queue.async {
            self.wantsScan = false
            if !(self.recording && self.peripheral == nil) { self.central?.stopScan() }
            self.publish { self.scanning = false }
        }
    }

    func choose(_ device: Found) {
        savedID = device.id
        defaults.set(device.name, forKey: "strapName")
        savedName = device.name
        stopScan()
    }

    func forget() {
        savedID = nil
        defaults.removeObject(forKey: "strapName")
        savedName = nil
    }

    // MARK: - Enregistrement

    /// Commence à écrire les mesures dans le dossier de la séance (la ceinture se reconnecte seule si besoin).
    func startRecording(directory: URL) {
        guard savedID != nil else { return }
        ensureCentral()
        queue.async {
            self.writer = try? JSONLinesWriter(url: directory.appendingPathComponent(ReferenceFiles.strap))
            self.recording = true
            self.samples = 0
            self.connect()
        }
    }

    func stopRecording() {
        queue.sync {
            recording = false
            writer?.close()
            writer = nil
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            peripheral = nil
            publish { self.status = "Arrêtée"; self.lastBPM = nil }
        }
    }

    private func connect() {
        guard recording, let central, central.state == .poweredOn, let id = savedID else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = known
            known.delegate = self
            // Une demande de connexion n'expire pas : elle aboutit dès que la ceinture est à portée.
            central.connect(known)
            publish { self.status = "Recherche…" }
        } else {
            central.scanForPeripherals(withServices: [Self.service])
        }
    }
}

extension ChestStrap: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let on = central.state == .poweredOn
        publish { self.bluetoothOff = !on }
        guard on else { return }
        if recording { connect() }
        if wantsScan { central.scanForPeripherals(withServices: [Self.service]) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Ceinture"
        let device = Found(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        publish {
            if let i = self.found.firstIndex(where: { $0.id == device.id }) { self.found[i].rssi = device.rssi }
            else { self.found.append(device) }
        }
        if recording, peripheral.identifier == savedID, self.peripheral == nil {
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onEvent?("Ceinture connectée (\(peripheral.name ?? "?"))")
        publish { self.status = "Connectée" }
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if recording { central.connect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard recording else { return }
        onEvent?("Ceinture déconnectée : reconnexion en attente")
        publish { self.status = "Recherche…"; self.lastBPM = nil }
        central.connect(peripheral)
    }
}

extension ChestStrap: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] where service.uuid == Self.service {
            peripheral.discoverCharacteristics([Self.measurement], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where c.uuid == Self.measurement {
            peripheral.setNotifyValue(true, for: c)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value,
              let sample = StrapSample.decode([UInt8](data), uptime: Clock.uptime) else { return }
        if recording {
            writer?.write(sample)
            samples += 1
        }
        let bpm = sample.bpm, contact = sample.contact
        publish {
            self.lastBPM = bpm
            self.status = contact == false ? "Connectée · mauvais contact" : "Connectée · \(bpm) bpm"
        }
    }
}
