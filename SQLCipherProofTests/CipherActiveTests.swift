import XCTest
import GRDB

/// Proofs that the SQLCipher codec is compiled in and actually engages.
final class CipherActiveTests: SQLCipherProofTestCase {
    // MARK: - Cipher presence

    func testCipherVersionIsNonEmpty() throws {
        let dbQueue = try DatabaseQueue()
        let version = try dbQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA cipher_version")
        }
        let cipherVersion = try XCTUnwrap(version, "PRAGMA cipher_version returned no row: SQLCipher is not compiled in")
        XCTAssertFalse(cipherVersion.isEmpty)
    }

    func testCipherProviderIsCommonCrypto() throws {
        // cipher_provider reports on keyed connections only.
        let dbQueue = try makeEncryptedQueue()
        let provider = try dbQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA cipher_provider")
        }
        XCTAssertEqual(provider, "commoncrypto")
    }

    // MARK: - On-disk format

    func testEncryptedDatabaseDoesNotStartWithPlaintextMagic() throws {
        let path = databasePath()
        do {
            let dbQueue = try makeEncryptedQueue()
            try dbQueue.write { db in
                try db.execute(sql: "CREATE TABLE data (value TEXT)")
                try db.execute(sql: "INSERT INTO data (value) VALUES ('top secret')")
            }
        }
        let header = try fileHeader(atPath: path)
        XCTAssertNotEqual(header, Self.plaintextMagic, "encrypted database file carries the plaintext SQLite header")
    }

    func testUnkeyedDatabaseIsPlainSQLiteWithPlaintextMagic() throws {
        // No passphrase: the codec must not engage, and the database must
        // work as a plain SQLite database.
        let path = databasePath()
        do {
            let dbQueue = try DatabaseQueue(path: path)
            try dbQueue.write { db in
                try db.execute(sql: "CREATE TABLE data (value TEXT)")
                try db.execute(sql: "INSERT INTO data (value) VALUES ('in the clear')")
            }
        }
        let header = try fileHeader(atPath: path)
        XCTAssertEqual(header, Self.plaintextMagic, "unkeyed database file should carry the plaintext SQLite header")

        // And it reopens without any key.
        let dbQueue = try DatabaseQueue(path: path)
        let value = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM data")
        }
        XCTAssertEqual(value, "in the clear")
    }

    // MARK: - Key enforcement

    func testOpeningEncryptedDatabaseWithoutKeyFails() throws {
        let path = databasePath()
        do {
            let dbQueue = try makeEncryptedQueue()
            try dbQueue.write { db in
                try db.execute(sql: "CREATE TABLE data (value TEXT)")
            }
        }
        do {
            let dbQueue = try DatabaseQueue(path: path)
            _ = try dbQueue.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM sqlite_master")
            }
            XCTFail("expected opening without a key to fail")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_NOTADB)
        }
    }

    func testOpeningEncryptedDatabaseWithWrongKeyFails() throws {
        let path = databasePath()
        do {
            let dbQueue = try makeEncryptedQueue(passphrase: "correct")
            try dbQueue.write { db in
                try db.execute(sql: "CREATE TABLE data (value TEXT)")
            }
        }
        do {
            _ = try DatabaseQueue(
                path: path,
                configuration: encryptedConfiguration(passphrase: "wrong"))
            XCTFail("expected opening with a wrong key to fail")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_NOTADB)
        }
    }

    func testCorrectKeyRoundTripsAcrossCloseAndReopen() throws {
        do {
            let dbQueue = try makeEncryptedQueue(passphrase: "round trip")
            try dbQueue.write { db in
                try db.execute(sql: "CREATE TABLE data (value TEXT)")
                try db.execute(sql: "INSERT INTO data (value) VALUES ('persisted')")
            }
        }
        let dbQueue = try makeEncryptedQueue(passphrase: "round trip")
        let value = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM data")
        }
        XCTAssertEqual(value, "persisted")
    }

    // MARK: - Rekey

    func testChangePassphraseInvalidatesOldKey() throws {
        let path = databasePath()
        do {
            let dbQueue = try makeEncryptedQueue(passphrase: "old key")
            try dbQueue.write { db in
                try db.execute(sql: "CREATE TABLE data (value TEXT)")
                try db.execute(sql: "INSERT INTO data (value) VALUES ('survives rekey')")
                try db.changePassphrase("new key")
            }
        }

        // Old key must fail.
        do {
            _ = try DatabaseQueue(
                path: path,
                configuration: encryptedConfiguration(passphrase: "old key"))
            XCTFail("expected the old key to fail after rekey")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_NOTADB)
        }

        // New key must work and see the data.
        let dbQueue = try makeEncryptedQueue(passphrase: "new key")
        let value = try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM data")
        }
        XCTAssertEqual(value, "survives rekey")

        // And the file is still not plaintext.
        let header = try fileHeader(atPath: path)
        XCTAssertNotEqual(header, Self.plaintextMagic)
    }
}
