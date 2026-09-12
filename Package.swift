// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Voltscope",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Voltscope", targets: ["Voltscope"]),
        .library(name: "VoltscopeCore", targets: ["VoltscopeCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "VoltscopeC",
            path: "Sources/VoltscopeC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "VoltscopeCore",
            dependencies: [
                "VoltscopeC",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/VoltscopeCore"
        ),
        .executableTarget(
            name: "Voltscope",
            dependencies: [
                "VoltscopeCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Voltscope",
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.svg",
                "Resources/AppIcon.icns"
            ]
            // IOReport is loaded at runtime via dlopen in
            // VoltscopeCore/Sampling/IOReport.swift — no link-time framework
            // dependency, so the build works under Command Line Tools where
            // the SDK doesn't ship private framework tbd files.
        ),
        .testTarget(
            name: "VoltscopeCoreTests",
            dependencies: ["VoltscopeCore"],
            path: "Tests/VoltscopeCoreTests"
        )
    ]
)
