// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Phone",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Phone", targets: ["Phone"]),
        .executable(name: "phone-mcp", targets: ["phone-mcp"])
    ],
    targets: [
        .target(name: "PhoneAutomation"),
        .executableTarget(
            name: "Phone",
            dependencies: ["PhoneAutomation"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .executableTarget(
            name: "phone-mcp",
            dependencies: ["PhoneAutomation"],
            path: "Sources/PhoneMCP"
        ),
        .testTarget(
            name: "PhoneTests",
            dependencies: ["Phone", "PhoneAutomation"],
            resources: [.process("Fixtures")]
        )
    ]
)
