// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Phone",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Phone", targets: ["Phone"])
    ],
    targets: [
        .executableTarget(
            name: "Phone",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(
            name: "PhoneTests",
            dependencies: ["Phone"]
        )
    ]
)
