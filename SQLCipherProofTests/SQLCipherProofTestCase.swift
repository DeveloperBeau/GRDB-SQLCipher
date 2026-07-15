import XCTest
import GRDB

/// Base class for the SQLCipher proof tests: provides a temporary directory,
/// helpers for opening keyed and unkeyed databases, and raw file inspection.
class SQLCipherProofTestCase: XCTestCase {
    /// The first 16 bytes of every plaintext SQLite database file.
    static let plaintextMagic = Data("SQLite format 3\0".utf8)

    private(set) var directoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SQLCipherProofTests", isDirectory: true)
            .appendingPathComponent(ProcessInfo.processInfo.globallyUniqueString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try super.tearDownWithError()
    }

    func databasePath(_ filename: String = "db.sqlite") -> String {
        directoryURL.appendingPathComponent(filename).path
    }

    func encryptedConfiguration(passphrase: String) -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.usePassphrase(passphrase)
        }
        return config
    }

    func makeEncryptedQueue(
        _ filename: String = "db.sqlite",
        passphrase: String = "secret"
    ) throws -> DatabaseQueue {
        try DatabaseQueue(
            path: databasePath(filename),
            configuration: encryptedConfiguration(passphrase: passphrase))
    }

    func makeEncryptedPool(
        _ filename: String = "db.sqlite",
        passphrase: String = "secret"
    ) throws -> DatabasePool {
        try DatabasePool(
            path: databasePath(filename),
            configuration: encryptedConfiguration(passphrase: passphrase))
    }

    /// The first 16 bytes of the database file at `path`.
    func fileHeader(atPath path: String) throws -> Data {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThanOrEqual(data.count, 16, "database file is unexpectedly small")
        return data.prefix(16)
    }
}
