import XCTest
import GRDB

/// A minimal lock-protected box (the package targets platforms older than
/// the Synchronization module).
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

private struct Team: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let players = hasMany(Player.self)
    var id: Int64
    var name: String
}

private struct Player: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let team = belongsTo(Team.self)
    var id: Int64
    var teamId: Int64
    var name: String
    var score: Int
}

/// Smoke tests for the GRDB feature surface, all running on an
/// encrypted database. The full upstream GRDBTests suite is the primary
/// functional evidence; these tests prove the main features work with the
/// codec engaged.
final class EncryptedGRDBSmokeTests: SQLCipherProofTestCase {
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "team") { t in
                t.column("id", .integer).primaryKey()
                t.column("name", .text).notNull()
            }
            try db.create(table: "player") { t in
                t.column("id", .integer).primaryKey()
                t.belongsTo("team").notNull()
                t.column("name", .text).notNull()
                t.column("score", .integer).notNull()
            }
        }
        return migrator
    }

    func testMigrationsOnEncryptedDatabase() throws {
        let dbQueue = try makeEncryptedQueue()
        try migrator.migrate(dbQueue)
        let tables = try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name")
        }
        XCTAssertEqual(tables, ["player", "team"])

        // Migrations are not reapplied on reopen.
        let reopened = try makeEncryptedQueue()
        try migrator.migrate(reopened)
        let migrations = try reopened.read { db in
            try migrator.appliedMigrations(db)
        }
        XCTAssertEqual(migrations, ["v1"])
    }

    func testCodableRecordRoundTrip() throws {
        let dbQueue = try makeEncryptedQueue()
        try migrator.migrate(dbQueue)

        let team = Team(id: 1, name: "Reds")
        let player = Player(id: 1, teamId: 1, name: "Arthur", score: 100)
        try dbQueue.write { db in
            try team.insert(db)
            try player.insert(db)
        }

        let fetched = try dbQueue.read { db in
            try Player.fetchOne(db, key: 1)
        }
        XCTAssertEqual(fetched, player)
    }

    func testAssociations() throws {
        let dbQueue = try makeEncryptedQueue()
        try migrator.migrate(dbQueue)

        try dbQueue.write { db in
            try Team(id: 1, name: "Reds").insert(db)
            try Team(id: 2, name: "Blues").insert(db)
            try Player(id: 1, teamId: 1, name: "Arthur", score: 100).insert(db)
            try Player(id: 2, teamId: 1, name: "Barbara", score: 250).insert(db)
            try Player(id: 3, teamId: 2, name: "Craig", score: 50).insert(db)
        }

        // hasMany
        let redPlayers = try dbQueue.read { db in
            let team = try XCTUnwrap(Team.fetchOne(db, key: 1))
            return try team.request(for: Team.players).order(Column("id")).fetchAll(db)
        }
        XCTAssertEqual(redPlayers.map(\.name), ["Arthur", "Barbara"])

        // belongsTo, with a joined request
        struct PlayerInfo: Codable, FetchableRecord, Equatable {
            var player: Player
            var team: Team
        }
        let infos = try dbQueue.read { db in
            try Player
                .including(required: Player.team)
                .order(Column("id"))
                .asRequest(of: PlayerInfo.self)
                .fetchAll(db)
        }
        XCTAssertEqual(infos.count, 3)
        XCTAssertEqual(infos[0].team.name, "Reds")
        XCTAssertEqual(infos[2].team.name, "Blues")
    }

    func testDatabasePoolWALWithConcurrentReads() throws {
        let pool = try makeEncryptedPool()
        try migrator.migrate(pool)

        // WAL mode is actually on.
        let journalMode = try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(journalMode?.lowercased(), "wal")

        try pool.write { db in
            try Team(id: 1, name: "Reds").insert(db)
            for id in 1...100 {
                try Player(id: Int64(id), teamId: 1, name: "Player \(id)", score: id).insert(db)
            }
        }

        // Concurrent reads while a write happens.
        let counts = LockedBox<[Int]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do {
                if index == 0 {
                    try pool.write { db in
                        try Player(id: 101, teamId: 1, name: "Late joiner", score: 0).insert(db)
                    }
                } else {
                    let count = try pool.read { db in
                        try Player.fetchCount(db)
                    }
                    counts.withLock { $0.append(count) }
                }
            } catch {
                XCTFail("concurrent access failed: \(error)")
            }
        }
        // Every read saw a consistent snapshot: either 100 or 101 players.
        XCTAssertEqual(counts.withLock { $0 }.count, 7)
        for count in counts.withLock({ $0 }) {
            XCTAssertTrue(count == 100 || count == 101, "inconsistent read: \(count)")
        }
    }

    func testValueObservationDeliversChanges() throws {
        let dbQueue = try makeEncryptedQueue()
        try migrator.migrate(dbQueue)
        try dbQueue.write { db in
            try Team(id: 1, name: "Reds").insert(db)
        }

        let expectation = self.expectation(description: "observation delivers initial value and change")
        expectation.expectedFulfillmentCount = 2

        let observedCounts = LockedBox<[Int]>([])
        let observation = ValueObservation.tracking { db in
            try Player.fetchCount(db)
        }
        let cancellable = observation.start(
            in: dbQueue,
            onError: { error in XCTFail("observation failed: \(error)") },
            onChange: { count in
                observedCounts.withLock { $0.append(count) }
                expectation.fulfill()
            })
        defer { cancellable.cancel() }

        try dbQueue.write { db in
            try Player(id: 1, teamId: 1, name: "Arthur", score: 100).insert(db)
        }

        waitForExpectations(timeout: 5)
        XCTAssertEqual(observedCounts.withLock { $0 }, [0, 1])
    }

    func testTransactionRollbackIsAtomic() throws {
        let dbQueue = try makeEncryptedQueue()
        try migrator.migrate(dbQueue)

        struct Cancel: Error { }
        do {
            // DatabaseQueue.write wraps the block in a transaction, and
            // a thrown error rolls it back.
            try dbQueue.write { db in
                try Team(id: 1, name: "Reds").insert(db)
                try Player(id: 1, teamId: 1, name: "Arthur", score: 100).insert(db)
                throw Cancel()
            }
            XCTFail("expected the transaction to rethrow")
        } catch is Cancel {
        }

        let (teamCount, playerCount) = try dbQueue.read { db in
            (try Team.fetchCount(db), try Player.fetchCount(db))
        }
        XCTAssertEqual(teamCount, 0)
        XCTAssertEqual(playerCount, 0)
    }

    func testSavepointRollbackIsAtomic() throws {
        let dbQueue = try makeEncryptedQueue()
        try migrator.migrate(dbQueue)

        struct Cancel: Error { }
        try dbQueue.write { db in
            try Team(id: 1, name: "Reds").insert(db)
            do {
                try db.inSavepoint {
                    try Player(id: 1, teamId: 1, name: "Arthur", score: 100).insert(db)
                    try Player(id: 2, teamId: 1, name: "Barbara", score: 250).insert(db)
                    throw Cancel()
                }
                XCTFail("expected the savepoint to rethrow")
            } catch is Cancel {
            }
        }

        let (teamCount, playerCount) = try dbQueue.read { db in
            (try Team.fetchCount(db), try Player.fetchCount(db))
        }
        XCTAssertEqual(teamCount, 1, "the outer transaction must survive")
        XCTAssertEqual(playerCount, 0, "the savepoint must roll back atomically")
    }

    func testFTS5() throws {
        let dbQueue = try makeEncryptedQueue()
        try dbQueue.write { db in
            try db.create(virtualTable: "document", using: FTS5()) { t in
                t.column("title")
                t.column("body")
            }
            try db.execute(sql: "INSERT INTO document (title, body) VALUES ('Encryption', 'SQLCipher encrypts SQLite databases')")
            try db.execute(sql: "INSERT INTO document (title, body) VALUES ('Cooking', 'A recipe for onion soup')")
        }

        let matches = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT title FROM document WHERE document MATCH ?", arguments: ["sqlcipher"])
        }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0]["title"] as String?, "Encryption")
    }
}
