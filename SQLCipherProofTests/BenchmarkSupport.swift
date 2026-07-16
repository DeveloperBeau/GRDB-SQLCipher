import XCTest
import GRDB
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Modes

/// A database "mode" under test. Every axis runs each relevant mode and we
/// report the encrypted-vs-plain ratio.
enum BenchMode: CustomStringConvertible, Sendable {
    /// Unencrypted SQLite (the baseline).
    case plain
    /// SQLCipher with a passphrase (KDF runs on open). `pageSize` is the
    /// `cipher_page_size`; the app ships 8192.
    case encryptedPassphrase(pageSize: Int)
    /// SQLCipher with a raw 32-byte key (no PBKDF2 on open).
    case encryptedRawKey(pageSize: Int)

    var description: String {
        switch self {
        case .plain: return "plain"
        case .encryptedPassphrase(let ps): return "encrypted(pass,page=\(ps))"
        case .encryptedRawKey(let ps): return "encrypted(rawkey,page=\(ps))"
        }
    }

    var isEncrypted: Bool {
        if case .plain = self { return false }
        return true
    }
}

/// The passphrase used for every encrypted benchmark. A realistic passphrase,
/// so the 256000-iteration PBKDF2 cost is representative.
let benchPassphrase = "correct horse battery staple - benchmark"

/// A raw 32-byte key expressed as 64 hex chars. Supplying a raw key makes
/// SQLCipher skip the expensive PBKDF2 derivation on open.
let benchRawKeyHex = "2dd29ca851e7b56e4697b0e1f08507293d761a05ce4d1b628663f411a8086d99"

// MARK: - Config

/// Builds a Configuration for the given mode. `busyTimeout` and
/// `walAutocheckpoint` are exposed because they are part of what we measure /
/// recommend.
func makeConfig(
    _ mode: BenchMode,
    busyTimeout: TimeInterval = 5,
    maximumReaderCount: Int = 5,
    walAutocheckpoint: Int? = nil
) -> Configuration {
    var config = Configuration()
    config.busyMode = .timeout(busyTimeout)
    config.maximumReaderCount = maximumReaderCount
    config.prepareDatabase { db in
        switch mode {
        case .plain:
            break
        case .encryptedPassphrase(let pageSize):
            try db.usePassphrase(benchPassphrase)
            // cipher_page_size must be set right after keying, before any read.
            try db.execute(sql: "PRAGMA cipher_page_size = \(pageSize)")
        case .encryptedRawKey(let pageSize):
            try db.execute(sql: "PRAGMA key = \"x'\(benchRawKeyHex)'\"")
            try db.execute(sql: "PRAGMA cipher_page_size = \(pageSize)")
        }
        if let walAutocheckpoint {
            try db.execute(sql: "PRAGMA wal_autocheckpoint = \(walAutocheckpoint)")
        }
    }
    return config
}

// MARK: - Schema

enum BenchSchema {
    /// A "messages"-like table plus a wide "profiles"-like table, modelling the
    /// consuming app's shape.
    static func create(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE message (
                id TEXT PRIMARY KEY,
                group_id TEXT NOT NULL,
                sender TEXT NOT NULL,
                payload BLOB NOT NULL,
                timestamp INTEGER NOT NULL
            ) WITHOUT ROWID
            """)
        try db.execute(sql: "CREATE INDEX message_on_group ON message(group_id)")
        try db.execute(sql: "CREATE INDEX message_on_timestamp ON message(timestamp)")

        // Wide profiles table: 20 columns to stand in for a fat record.
        let cols = (0..<16).map { "c\($0) TEXT" }.joined(separator: ", ")
        try db.execute(sql: """
            CREATE TABLE profile (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                \(cols)
            ) WITHOUT ROWID
            """)
    }

    /// A deterministic pseudo-random payload of a given size. Size varies
    /// 256-1024 bytes to stand in for an encrypted blob.
    static func payload(seed: Int) -> Data {
        let size = 256 + (seed % 769) // 256...1024
        var data = Data(count: size)
        var x = UInt64(truncatingIfNeeded: seed) &* 2654435761 &+ 1
        for i in 0..<size {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            data[i] = UInt8(truncatingIfNeeded: x >> 33)
        }
        return data
    }

    /// Inserts `count` messages into the open database, in transactions of
    /// `batchSize` rows each. Returns the number of transactions committed.
    @discardableResult
    static func insertMessages(
        _ writer: some DatabaseWriter,
        count: Int,
        batchSize: Int,
        startIndex: Int = 0
    ) throws -> Int {
        var committed = 0
        var i = startIndex
        let end = startIndex + count
        while i < end {
            let upper = min(i + batchSize, end)
            try writer.write { db in
                let stmt = try db.makeStatement(sql: """
                    INSERT INTO message (id, group_id, sender, payload, timestamp)
                    VALUES (?, ?, ?, ?, ?)
                    """)
                var j = i
                while j < upper {
                    stmt.setUncheckedArguments([
                        "msg-\(j)",
                        "group-\(j % 1000)",
                        "sender-\(j % 5000)",
                        payload(seed: j),
                        1_600_000_000 + j,
                    ])
                    try stmt.execute()
                    j += 1
                }
            }
            committed += 1
            i = upper
        }
        return committed
    }
}

// MARK: - Timing & measurement

@discardableResult
func seconds(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    let end = DispatchTime.now().uptimeNanoseconds
    return Double(end - start) / 1_000_000_000
}

/// Resident memory of this process, in bytes.
func residentMemoryBytes() -> UInt64 {
    #if canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
    #else
    return 0
    #endif
}

func fileSizeBytes(_ path: String) -> Int64 {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attrs[.size] as? Int64 else { return 0 }
    return size
}

// MARK: - Result reporting

/// One measured cell: a mode plus its elapsed time.
struct BenchCell {
    let mode: BenchMode
    let seconds: Double
    var rowsPerSecond: Double?
}

/// Prints a table for one axis and the encrypted/plain overhead. Every line is
/// prefixed with `BENCH|` so it is trivially greppable out of the test log.
func report(_ axis: String, _ cells: [BenchCell], note: String? = nil) {
    let plain = cells.first { if case .plain = $0.mode { return true }; return false }
    print("BENCH| ==== \(axis) ====")
    for cell in cells {
        var line = "BENCH| \(axis) | \(cell.mode) | \(String(format: "%.3f", cell.seconds))s"
        if let rps = cell.rowsPerSecond {
            line += " | \(Int(rps)) rows/s"
        }
        if let plain, plain.seconds > 0, cell.mode.isEncrypted {
            let overhead = (cell.seconds / plain.seconds - 1) * 100
            line += " | +\(String(format: "%.1f", overhead))% vs plain"
        }
        print(line)
    }
    if let note {
        print("BENCH| \(axis) | note: \(note)")
    }
}

/// Whether the heavy (1M-row / long-running) cases should run.
var runHeavy: Bool {
    ProcessInfo.processInfo.environment["RUN_HEAVY_BENCH"] == "1"
}
