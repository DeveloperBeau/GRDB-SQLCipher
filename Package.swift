// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let darwinPlatforms: [Platform] = [
    .iOS,
    .macOS,
    .macCatalyst,
    .tvOS,
    .visionOS,
    .watchOS,
]
var swiftSettings: [SwiftSetting] = [
    .define("SQLITE_ENABLE_FTS5"),
    .define("SQLITE_ENABLE_SNAPSHOT"),
    // Not all Linux distributions have support for WAL snapshots.
    .define("SQLITE_DISABLE_SNAPSHOT", .when(platforms: [.linux])),
]
var cSettings: [CSetting] = []
var dependencies: [PackageDescription.Package.Dependency] = []

// Don't rely on those environment variables. They are ONLY testing conveniences:
// $ SQLITE_ENABLE_PREUPDATE_HOOK=1 make test_SPM
if ProcessInfo.processInfo.environment["SQLITE_ENABLE_PREUPDATE_HOOK"] == "1" {
    swiftSettings.append(.define("SQLITE_ENABLE_PREUPDATE_HOOK"))
    cSettings.append(.define("GRDB_SQLITE_ENABLE_PREUPDATE_HOOK"))
}

// The SPI_BUILDER environment variable enables documentation building
// on <https://swiftpackageindex.com/groue/GRDB.swift>. See
// <https://github.com/SwiftPackageIndex/SwiftPackageIndex-Server/issues/2122>
// for more information.
//
// SPI_BUILDER also enables the `make docs-localhost` command.
if ProcessInfo.processInfo.environment["SPI_BUILDER"] == "1" {
    dependencies.append(.package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"))
}

// GRDB+SQLCipher: build against the vendored SQLCipher amalgamation
// (Sources/SQLCipher) instead of the system SQLite.
cSettings.append(.define("SQLITE_HAS_CODEC"))
swiftSettings.append(.define("SQLITE_HAS_CODEC"))
swiftSettings.append(.define("SQLCipher"))

// Compilation flags for the vendored SQLCipher amalgamation. The first five
// are required by SQLCipher (see its README); the rest enable the SQLite
// features GRDB expects from Apple's system SQLite.
let sqlcipherCSettings: [CSetting] = [
    // NDEBUG must be on the command line, not just defined by sqlite3.c
    // itself: clang modules otherwise re-activate assert() after the
    // CommonCrypto include, referencing assert-only private functions.
    .define("NDEBUG"),
    .define("SQLITE_HAS_CODEC"),
    .define("SQLITE_TEMP_STORE", to: "2"),
    .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
    .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
    .define("SQLCIPHER_CRYPTO_CC"), // CommonCrypto provider, no OpenSSL
    .define("SQLITE_THREADSAFE", to: "2"),
    .define("HAVE_USLEEP", to: "1"),
    .define("SQLITE_ENABLE_API_ARMOR"),
    .define("SQLITE_ENABLE_FTS3_PARENTHESIS"),
    .define("SQLITE_ENABLE_FTS4"),
    .define("SQLITE_ENABLE_FTS5"),
    .define("SQLITE_ENABLE_MATH_FUNCTIONS"),
    .define("SQLITE_ENABLE_RTREE"),
    .define("SQLITE_ENABLE_SNAPSHOT"),
    .define("SQLITE_ENABLE_STAT4"),
]

let package = Package(
    name: "GRDB",
    defaultLocalization: "en", // for tests
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v7),
    ],
    products: [
        .library(name: "GRDB", targets: ["GRDB"]),
        .library(name: "GRDB-dynamic", type: .dynamic, targets: ["GRDB"]),
    ],
    dependencies: dependencies,
    targets: [
        // The SQLCipher amalgamation, generated from sqlcipher/sqlcipher
        // sources. See README.md for the version and generation command.
        .target(
            name: "SQLCipher",
            exclude: ["LICENSE.txt"],
            cSettings: sqlcipherCSettings,
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
            ]),
        .target(
            name: "GRDBSQLCipher",
            dependencies: [.target(name: "SQLCipher")]
        ),
        .target(
            name: "GRDB",
            dependencies: [
                .target(name: "SQLCipher"),
                .target(name: "GRDBSQLCipher"),
            ],
            path: "GRDB",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            cSettings: cSettings,
            swiftSettings: swiftSettings + [
                .enableUpcomingFeature("MemberImportVisibility"),
            ]),
        .testTarget(
            name: "GRDBTests",
            dependencies: ["GRDB"],
            path: "Tests",
            exclude: [
                "CocoaPods",
                "Crash",
                "CustomSQLite",
                "GRDBManualInstall",
                "GRDBTests/Core/DatabasePool/getThreadsCount.c",
                "Info.plist",
                "Performance",
                "SPM",
                "Swift6Migration",
                "generatePerformanceReport.rb",
                "parsePerformanceTests.rb",
            ],
            resources: [
                .copy("GRDBTests/Betty.jpeg"),
                .copy("GRDBTests/Private/InflectionsTests.json"),
                .copy("GRDBTests/ValueObservation/Issue1383.sqlite"),
                .copy("GRDBTests/GRDBCipher/db.SQLCipher3"),
            ],
            cSettings: cSettings,
            swiftSettings: swiftSettings + [
                // Tests still use the Swift 5 language mode.
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
            ]),
        // Proofs that the SQLCipher codec is active and that GRDB works on
        // encrypted databases. See SQLCipherProofTests/README notes.
        .testTarget(
            name: "SQLCipherProofTests",
            dependencies: ["GRDB"],
            path: "SQLCipherProofTests",
            cSettings: cSettings,
            swiftSettings: swiftSettings + [
                .swiftLanguageMode(.v5),
            ])
    ],
    swiftLanguageModes: [.v6]
)
