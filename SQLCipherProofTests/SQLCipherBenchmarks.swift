import XCTest
import GRDB
import Foundation

/// Performance + stability benchmarks comparing SQLCipher (encrypted) against
/// an unencrypted database in the same process, so the delta is apples-to-apples.
///
/// The app ships `cipher_page_size = 8192`; every encrypted case defaults to
/// that. Heavy (1M-row / long) cases are gated behind `RUN_HEAVY_BENCH=1`.
///
/// Run everything light:
///   swift test --filter SQLCipherBenchmarks
/// Run one axis:
///   swift test --filter SQLCipherBenchmarks/testBulkImport
/// Run the heavy 1M cases too:
///   RUN_HEAVY_BENCH=1 swift test --filter SQLCipherBenchmarks
///
/// Results are printed as `BENCH| ...` lines; grep the log for those.
final class SQLCipherBenchmarks: SQLCipherProofTestCase {

    /// The page size the app uses.
    static let appPageSize = 8192

    private func freshDBPath(_ name: String) -> String {
        let path = databasePath("\(name).sqlite")
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
        return path
    }

    // MARK: - Axis 1: Bulk import

    func testBulkImport() throws {
        let count = runHeavy ? 1_000_000 : 100_000
        let modes: [BenchMode] = [
            .plain,
            .encryptedPassphrase(pageSize: Self.appPageSize),
        ]

        // One big transaction vs many small.
        for (label, batchSize) in [("batched-10k", 10_000), ("per-row-txn", 1)] {
            // per-row-txn is brutal; only exercise it on the light size.
            if batchSize == 1 && count > 100_000 { continue }
            let perRowCount = batchSize == 1 ? min(count, 8_000) : count
            var cells: [BenchCell] = []
            for mode in modes {
                let path = freshDBPath("import-\(label)-\(mode)")
                let queue = try DatabaseQueue(path: path, configuration: makeConfig(mode))
                try queue.write { try BenchSchema.create($0) }
                let t = try seconds {
                    try BenchSchema.insertMessages(queue, count: perRowCount, batchSize: batchSize)
                }
                cells.append(BenchCell(mode: mode, seconds: t, rowsPerSecond: Double(perRowCount) / t))
            }
            report("import/\(label)/\(count == 1_000_000 ? "1M" : "100k")", cells,
                   note: "rows=\(perRowCount) batch=\(batchSize)")
        }
    }

    // MARK: - Axis 2: Bulk update

    func testBulkUpdate() throws {
        let count = runHeavy ? 1_000_000 : 100_000
        let modes: [BenchMode] = [
            .plain,
            .encryptedPassphrase(pageSize: Self.appPageSize),
        ]

        for kind in ["full-table", "indexed"] {
            var cells: [BenchCell] = []
            for mode in modes {
                let path = freshDBPath("update-\(kind)-\(mode)")
                let queue = try DatabaseQueue(path: path, configuration: makeConfig(mode))
                try queue.write { try BenchSchema.create($0) }
                try BenchSchema.insertMessages(queue, count: count, batchSize: 10_000)

                let t = try seconds {
                    try queue.write { db in
                        if kind == "full-table" {
                            try db.execute(sql: "UPDATE message SET sender = sender || '-x'")
                        } else {
                            // Touches ~1/1000 of rows via the group_id index.
                            try db.execute(sql: "UPDATE message SET sender = 'touched' WHERE group_id = 'group-7'")
                        }
                    }
                }
                cells.append(BenchCell(mode: mode, seconds: t, rowsPerSecond: nil))
            }
            report("update/\(kind)/\(count == 1_000_000 ? "1M" : "100k")", cells)
        }
    }

    // MARK: - Axis 3: Cold-open at scale

    func testColdOpenAtScale() throws {
        // Build a DB, close it, then measure open + first indexed query. This is
        // the "open a 1M-record encrypted DB" cost. On open SQLCipher runs the
        // KDF (256000 PBKDF2 iters for a passphrase) and decrypts page headers.
        let count = runHeavy ? 1_000_000 : 100_000
        let modes: [BenchMode] = [
            .plain,
            .encryptedPassphrase(pageSize: 4096),
            .encryptedPassphrase(pageSize: 8192),
            .encryptedRawKey(pageSize: 8192),
        ]
        var cells: [BenchCell] = []
        for mode in modes {
            let path = freshDBPath("coldopen-\(mode)")
            // Build phase (not timed).
            do {
                let queue = try DatabaseQueue(path: path, configuration: makeConfig(mode))
                try queue.write { try BenchSchema.create($0) }
                try BenchSchema.insertMessages(queue, count: count, batchSize: 10_000)
                try queue.writeWithoutTransaction { db in
                    _ = try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                }
            } // queue deallocated -> connection closed

            // Timed phase: open + first query. Average a few opens.
            let attempts = 5
            var total = 0.0
            for _ in 0..<attempts {
                let t = try seconds {
                    let queue = try DatabaseQueue(path: path, configuration: makeConfig(mode))
                    _ = try queue.read { db in
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE group_id = 'group-42'")
                    }
                }
                total += t
            }
            cells.append(BenchCell(mode: mode, seconds: total / Double(attempts), rowsPerSecond: nil))
        }
        report("cold-open/\(count == 1_000_000 ? "1M" : "100k")", cells,
               note: "open+first-query, avg of 5; passphrase pays PBKDF2, raw key does not")
    }

    // MARK: - Axis 4: Rapid CRUD

    func testRapidCRUD() throws {
        let ops = runHeavy ? 200_000 : 15_000
        let modes: [BenchMode] = [
            .plain,
            .encryptedPassphrase(pageSize: Self.appPageSize),
        ]
        var cells: [BenchCell] = []
        for mode in modes {
            let path = freshDBPath("crud-\(mode)")
            let queue = try DatabaseQueue(path: path, configuration: makeConfig(mode))
            try queue.write { try BenchSchema.create($0) }
            // Seed a working set.
            try BenchSchema.insertMessages(queue, count: 10_000, batchSize: 10_000)

            var lockErrors = 0
            let t = try seconds {
                for k in 0..<ops {
                    do {
                        try queue.write { db in
                            switch k % 4 {
                            case 0:
                                let stmt = try db.makeStatement(sql: """
                                    INSERT OR REPLACE INTO message (id, group_id, sender, payload, timestamp)
                                    VALUES (?, ?, ?, ?, ?)
                                    """)
                                stmt.setUncheckedArguments([
                                    "live-\(k)", "group-\(k % 100)", "s", BenchSchema.payload(seed: k), 1_600_000_000 + k,
                                ])
                                try stmt.execute()
                            case 1:
                                _ = try Row.fetchOne(db, sql: "SELECT * FROM message WHERE id = ?", arguments: ["msg-\(k % 10_000)"])
                            case 2:
                                try db.execute(sql: "UPDATE message SET timestamp = timestamp + 1 WHERE id = ?", arguments: ["msg-\(k % 10_000)"])
                            default:
                                try db.execute(sql: "DELETE FROM message WHERE id = ?", arguments: ["live-\(k - 3)"])
                            }
                        }
                    } catch let e as DatabaseError where e.resultCode == .SQLITE_BUSY || e.resultCode == .SQLITE_LOCKED {
                        lockErrors += 1
                    }
                }
            }
            XCTAssertEqual(lockErrors, 0, "\(mode): saw \(lockErrors) lock/timeout errors")
            cells.append(BenchCell(mode: mode, seconds: t, rowsPerSecond: Double(ops) / t))
        }
        report("rapid-crud/\(ops)ops", cells, note: "interleaved insert/read/update/delete; lock errors asserted 0")
    }

    // MARK: - Axis 5: Concurrency / stability

    func testConcurrencyStability() throws {
        // A DatabasePool: N concurrent readers + a writer under WAL, encrypted.
        // Assert no corruption (integrity_check) and no lock errors, and report
        // WAL growth + checkpoint behaviour.
        let mode: BenchMode = .encryptedPassphrase(pageSize: Self.appPageSize)
        let path = freshDBPath("concurrency-\(mode)")
        let pool = try DatabasePool(path: path, configuration: makeConfig(mode, maximumReaderCount: 8))
        try pool.write { try BenchSchema.create($0) }
        try BenchSchema.insertMessages(pool, count: 20_000, batchSize: 10_000)

        let walPath = path + "-wal"
        let writes = runHeavy ? 40_000 : 3_000
        let readerCount = 6
        var peakWAL: Int64 = 0

        let group = DispatchGroup()
        let lockErrors = LockedInt()

        // Writer.
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for k in 0..<writes {
                do {
                    try pool.write { db in
                        try db.execute(sql: """
                            INSERT OR REPLACE INTO message (id, group_id, sender, payload, timestamp)
                            VALUES (?, ?, ?, ?, ?)
                            """, arguments: ["w-\(k)", "group-\(k % 200)", "writer", BenchSchema.payload(seed: k), 1_600_000_000 + k])
                    }
                } catch let e as DatabaseError where e.resultCode == .SQLITE_BUSY || e.resultCode == .SQLITE_LOCKED {
                    lockErrors.increment()
                } catch {
                    XCTFail("writer failed: \(error)")
                }
            }
        }

        // Readers.
        for r in 0..<readerCount {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                for k in 0..<writes {
                    do {
                        _ = try pool.read { db in
                            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE group_id = ?", arguments: ["group-\((k + r) % 200)"])
                        }
                    } catch let e as DatabaseError where e.resultCode == .SQLITE_BUSY || e.resultCode == .SQLITE_LOCKED {
                        lockErrors.increment()
                    } catch {
                        XCTFail("reader failed: \(error)")
                    }
                }
            }
        }

        // WAL watcher. It must NOT be a member of `group` — it watches the
        // workers' group to know when to stop, so joining that same group
        // would keep the count above zero forever and deadlock both its own
        // loop and the outer wait. It signals its own completion instead.
        let watcherDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while group.wait(timeout: .now() + 0.05) == .timedOut {
                peakWAL = max(peakWAL, fileSizeBytes(walPath))
            }
            watcherDone.signal()
        }

        group.wait()
        watcherDone.wait()

        XCTAssertEqual(lockErrors.value, 0, "saw \(lockErrors.value) lock/timeout errors under contention")

        // Integrity must pass, no corruption.
        let integrity = try pool.read { db in try String.fetchOne(db, sql: "PRAGMA integrity_check") }
        XCTAssertEqual(integrity, "ok", "integrity_check failed: \(integrity ?? "nil")")

        // Force a checkpoint and observe WAL shrink.
        try pool.writeWithoutTransaction { db in _ = try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        let walAfter = fileSizeBytes(walPath)

        print("BENCH| ==== concurrency/stability ====")
        print("BENCH| concurrency | \(mode) | readers=\(readerCount) writes=\(writes) lockErrors=\(lockErrors.value)")
        print("BENCH| concurrency | integrity_check=\(integrity ?? "nil")")
        print("BENCH| concurrency | peak WAL=\(peakWAL / 1024)KB, WAL after TRUNCATE checkpoint=\(walAfter / 1024)KB")
    }

    // MARK: - Axis 5b: Try to break it (error injection, oversized/tiny txns)

    func testStabilityUnderAbuse() throws {
        let mode: BenchMode = .encryptedPassphrase(pageSize: Self.appPageSize)
        let path = freshDBPath("abuse-\(mode)")
        let pool = try DatabasePool(path: path, configuration: makeConfig(mode))
        try pool.write { try BenchSchema.create($0) }

        // 1. Error injection mid-transaction: throw after partial work; the
        // transaction must roll back and leave the DB consistent.
        struct Injected: Error {}
        for k in 0..<200 {
            do {
                try pool.write { db in
                    try db.execute(sql: "INSERT INTO message (id, group_id, sender, payload, timestamp) VALUES (?,?,?,?,?)",
                                   arguments: ["abort-\(k)", "g", "s", Data([1, 2, 3]), 0])
                    throw Injected() // simulate a kill mid-transaction
                }
                XCTFail("expected the injected error to propagate")
            } catch is Injected {
                // expected
            }
        }
        let leaked = try pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE id LIKE 'abort-%'") }
        XCTAssertEqual(leaked, 0, "aborted transactions leaked \(leaked ?? -1) rows")

        // 2. Oversized single transaction (one txn, many rows).
        try seconds {
            try pool.write { db in
                let stmt = try db.makeStatement(sql: "INSERT INTO message (id, group_id, sender, payload, timestamp) VALUES (?,?,?,?,?)")
                for k in 0..<100_000 {
                    stmt.setUncheckedArguments(["big-\(k)", "g", "s", BenchSchema.payload(seed: k), Int64(k)])
                    try stmt.execute()
                }
            }
        }

        // 3. Many tiny transactions.
        try seconds {
            for k in 0..<1_000 {
                try pool.write { db in
                    try db.execute(sql: "UPDATE message SET timestamp = timestamp + 1 WHERE id = ?", arguments: ["big-\(k)"])
                }
            }
        }

        let integrity = try pool.read { db in try String.fetchOne(db, sql: "PRAGMA integrity_check") }
        XCTAssertEqual(integrity, "ok", "integrity_check failed after abuse: \(integrity ?? "nil")")
        print("BENCH| ==== stability/abuse ====")
        print("BENCH| abuse | injected-rollback ok, oversized+tiny txns ok, integrity_check=\(integrity ?? "nil")")
    }

    // MARK: - Axis 6: Memory / WAL during a large import

    func testMemoryAndWALDuringImport() throws {
        let count = runHeavy ? 1_000_000 : 100_000
        let mode: BenchMode = .encryptedPassphrase(pageSize: Self.appPageSize)

        // Import in one long-running transaction with default wal_autocheckpoint
        // (1000 pages). WAL cannot checkpoint mid-transaction, so this shows the
        // worst case: WAL grows for the whole transaction.
        let pathBig = freshDBPath("mem-onetxn-\(mode)")
        let poolBig = try DatabasePool(path: pathBig, configuration: makeConfig(mode))
        try poolBig.write { try BenchSchema.create($0) }
        let baseMem = residentMemoryBytes()
        var peakMem = baseMem
        try poolBig.write { db in
            let stmt = try db.makeStatement(sql: """
                INSERT INTO message (id, group_id, sender, payload, timestamp) VALUES (?,?,?,?,?)
                """)
            for k in 0..<count {
                stmt.setUncheckedArguments(["m-\(k)", "group-\(k % 1000)", "s", BenchSchema.payload(seed: k), Int64(k)])
                try stmt.execute()
                if k % 50_000 == 0 { peakMem = max(peakMem, residentMemoryBytes()) }
            }
        }
        peakMem = max(peakMem, residentMemoryBytes())
        let walOneTxn = fileSizeBytes(pathBig + "-wal")

        // Import in batches so autocheckpoint can run: WAL should stay bounded.
        let pathBatched = freshDBPath("mem-batched-\(mode)")
        let poolBatched = try DatabasePool(path: pathBatched, configuration: makeConfig(mode))
        try poolBatched.write { try BenchSchema.create($0) }
        var peakWALBatched: Int64 = 0
        try BenchSchema.insertMessages(poolBatched, count: count, batchSize: 5_000)
        peakWALBatched = max(peakWALBatched, fileSizeBytes(pathBatched + "-wal"))

        print("BENCH| ==== memory/WAL ====")
        print("BENCH| memWAL | rows=\(count) mode=\(mode)")
        print("BENCH| memWAL | peak RSS during import=\((peakMem - baseMem) / (1024 * 1024))MB over baseline (\(baseMem / (1024*1024))MB)")
        print("BENCH| memWAL | WAL after single \(count)-row txn=\(walOneTxn / (1024 * 1024))MB (grows unbounded until commit)")
        print("BENCH| memWAL | peak WAL with 5k batches=\(peakWALBatched / (1024 * 1024))MB (autocheckpoint bounds it)")
    }
}

/// Trivial thread-safe counter for the concurrency test.
final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}
