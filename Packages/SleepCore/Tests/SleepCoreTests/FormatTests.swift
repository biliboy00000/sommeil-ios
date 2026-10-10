import XCTest
@testable import SleepCore

final class FormatTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sleepcore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testHeaderRoundTrip() {
        let header = StreamFileHeader(stream: .deviceMotion, nominalRate: 100, createdUptime: 12345.678,
                                      createdUnix: 1_760_000_000.25, chunkIndex: 7)
        let data = header.encoded()
        XCTAssertEqual(data.count, StreamFileHeader.size)
        XCTAssertEqual(StreamFileHeader.decode(data), header)
        XCTAssertEqual(header.recordSize, 60)
        XCTAssertNil(StreamFileHeader.decode(Data(repeating: 0, count: 64)))
    }

    func testRecordSizes() {
        XCTAssertEqual(SensorStream.deviceMotion.recordSize, 60)
        XCTAssertEqual(SensorStream.accelerometer.recordSize, 20)
        XCTAssertEqual(SensorStream.gyroscope.recordSize, 20)
    }

    func testWriterRotatesAndSurvivesTruncation() throws {
        let dir = try temporaryDirectory()
        var uptime = 1000.0
        let writer = ChunkedStreamWriter(stream: .accelerometer, directory: dir, nominalRate: 100,
                                         chunkDuration: 5, clock: { (uptime, 1_760_000_000 + uptime) })
        for i in 0..<1500 {
            let t = 1000.0 + Double(i) / 100
            uptime = t
            writer.append(timestamp: t, values: [Float(i), Float(-i), 0.5])
            if i % 100 == 0 { writer.flush() }
        }
        writer.close()
        XCTAssertEqual(writer.files.count, 3)
        XCTAssertEqual(writer.recordCount, 1500)
        XCTAssertEqual(writer.droppedCount, 0)

        var all: [SensorRecord] = []
        for url in writer.files {
            let (header, records) = try SensorFileReader.read(url)
            XCTAssertEqual(header.stream, .accelerometer)
            all += records
        }
        XCTAssertEqual(all.count, 1500)
        XCTAssertEqual(all[1234].values, [1234, -1234, 0.5])
        XCTAssertEqual(all[1234].timestamp, 1000 + 12.34, accuracy: 1e-9)

        // Arrêt brutal simulé : le dernier enregistrement est coupé en deux.
        let last = writer.files[2]
        let data = try Data(contentsOf: last)
        try data.prefix(data.count - 7).write(to: last)
        let (_, truncated) = try SensorFileReader.read(last)
        XCTAssertEqual(truncated.count, 499)
    }

    func testWrongValueCountIsDropped() throws {
        let dir = try temporaryDirectory()
        let writer = ChunkedStreamWriter(stream: .gyroscope, directory: dir, nominalRate: 100,
                                         clock: { (0, 0) })
        writer.append(timestamp: 1, values: [1, 2])
        writer.close()
        XCTAssertEqual(writer.droppedCount, 1)
        XCTAssertEqual(writer.recordCount, 0)
    }

    func testJSONLinesIgnoresBrokenLastLine() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("journal.jsonl")
        let writer = try JSONLinesWriter(url: url)
        writer.write(JournalEvent(unix: 1, uptime: 2, type: "a", message: "un"))
        writer.write(JournalEvent(unix: 3, uptime: 4, type: "b", message: "deux", values: ["x": 1.5]))
        writer.close()
        var data = try Data(contentsOf: url)
        data.append(contentsOf: Array("{\"unix\":5,\"upt".utf8))
        try data.write(to: url)
        let events = JSONLinesWriter.read(JournalEvent.self, from: url)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].values?["x"], 1.5)

        // Réouverture : on continue à la suite.
        let again = try JSONLinesWriter(url: url)
        again.write(JournalEvent(unix: 6, uptime: 7, type: "c", message: "trois"))
        again.close()
        XCTAssertEqual(JSONLinesWriter.read(JournalEvent.self, from: url).map(\.type), ["a", "b", "c"])
    }

    func testSessionIDAndInfoRoundTrip() throws {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(SessionInfo.makeID(startUnix: 0, timeZone: utc), "1970-01-01_00h00m00")
        let dir = try temporaryDirectory()
        var info = SessionInfo(id: "x", kind: "nuit", appVersion: "1", device: "iPhone15,2",
                               systemVersion: "26.0", startUnix: 10, startUptime: 20, nominalRate: 100,
                               streams: ["dm"])
        info.calibration = Calibration(startUnix: 10, endUnix: 40, gravity: [0, 0, -1], movement: 0.001, samples: 3000)
        try info.write(to: dir)
        XCTAssertEqual(try SessionInfo.read(from: dir), info)
    }

    func testProvisioningParse() {
        var data = Data([0x30, 0x82, 0x01, 0x02, 0x06])
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Name</key><string>iOS Team Provisioning Profile: *</string>
        <key>TeamName</key><string>Jean Dupont</string>
        <key>CreationDate</key><date>2026-10-10T10:00:00Z</date>
        <key>ExpirationDate</key><date>2026-10-17T10:00:00Z</date>
        </dict></plist>
        """
        data.append(contentsOf: Array(xml.utf8))
        data.append(contentsOf: [0xA0, 0x82, 0x00])
        let info = ProvisioningInfo.parse(data)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.teamName, "Jean Dupont")
        XCTAssertEqual(info?.expiration?.timeIntervalSince1970 ?? 0,
                       info!.creation!.timeIntervalSince1970 + 7 * 86_400, accuracy: 1)
        XCTAssertEqual(info?.daysRemaining(now: info!.creation!) ?? 0, 7, accuracy: 0.001)
        XCTAssertNil(ProvisioningInfo.parse(Data("rien".utf8)))
    }
}
