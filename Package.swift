// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Parrot",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // On-device speaker diarization (CoreML pyannote pipeline). Pinned:
        // young project, and the clustering threshold is calibrated per version.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
        // Vendored SpeexDSP for acoustic echo cancellation. Kept in sync with
        // project.yml (the xcodegen source of truth) so `swift build` works too.
        .package(path: "Vendor/CSpeexDSP"),
        // Self-updating. Sparkle is a binary XCFramework, so the Makefile has
        // to copy it into Contents/Frameworks itself — `swift build` links it
        // but never embeds it (see the bundle step).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
    ],
    targets: [
        .executableTarget(
            name: "Parrot",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "CSpeexDSP", package: "CSpeexDSP"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Parrot",
            linkerSettings: [
                // The framework lives next to the executable in the bundle.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
    ]
)
