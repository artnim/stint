// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TimeCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TimeCore", targets: ["TimeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "TimeCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "TimeCoreTests",
            dependencies: ["TimeCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
