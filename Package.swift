// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Typist",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Typist", targets: ["Typist"]),
        .library(name: "TypistCore", targets: ["TypistCore"]),
    ],
    targets: [
        // Prebuilt llama.cpp (MIT) from the official release page.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11559/llama-b11559-xcframework.zip",
            checksum: "433c3326bf21c6e98cbf075c624aba5c42b9432291d758722bb29b29fe33a700"
        ),
        // Pure, UI-free logic: prompt building, suggestion state, policies.
        .target(name: "TypistCore"),
        .executableTarget(
            name: "Typist",
            dependencies: ["TypistCore", "llama"]
        ),
        .testTarget(name: "TypistCoreTests", dependencies: ["TypistCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
