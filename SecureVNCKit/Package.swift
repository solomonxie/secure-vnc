// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SecureVNCKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SecureVNCKit", targets: ["SecureVNCKit"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh", from: "0.9.1"),
        .package(url: "https://github.com/attaswift/BigInt", from: "5.5.0"),
    ],
    targets: [
        .target(
            name: "SecureVNCKit",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "BigInt", package: "BigInt"),
            ],
            exclude: ["README.md"],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(name: "SecureVNCKitTests", dependencies: ["SecureVNCKit"]),
    ],
    swiftLanguageVersions: [.v5]
)
