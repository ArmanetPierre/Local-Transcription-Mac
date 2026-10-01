// swift-tools-version: 5.10

import PackageDescription

// Moteur de transcription natif de Voxa (sans Python) :
// WhisperKit (transcription) + SpeakerKit (diarisation), sur Core ML.
// L'executable voxa-engine parle le meme protocole JSON Lines que
// transcribe_bridge.py, l'app et le banc de mesure l'utilisent tel quel.
let package = Package(
    name: "VoxaEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VoxaEngine", targets: ["VoxaEngine"]),
        .executable(name: "voxa-engine", targets: ["voxa-engine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
    ],
    targets: [
        .target(
            name: "VoxaEngine",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ]
        ),
        .executableTarget(
            name: "voxa-engine",
            dependencies: ["VoxaEngine"]
        ),
        .testTarget(
            name: "VoxaEngineTests",
            dependencies: ["VoxaEngine"]
        ),
    ]
)
