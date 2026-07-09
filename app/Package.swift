// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Blaise",
    // String form required: .macOS(.v26) needs PackageDescription 6.2.
    platforms: [.macOS("26.1")],
    products: [
        .executable(name: "Blaise", targets: ["BlaiseApp"]),
        .library(name: "BlaiseCore", targets: ["BlaiseCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.0"),
        // C3: Parakeet v3 CoreML runtime (decision D5). Apache-2.0; NOTICE in README.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.2"),
        // Estúdio Fluido (design v3) micro-delight: Pow change effects
        // (MIT). UI-only — BlaiseApp target, never core. (Vortex 1.0.4 was
        // evaluated and DROPPED: its asset catalog needs actool, which this
        // machine's unaccepted Xcode license blocks, so SwiftPM never
        // generates its Bundle.module — the sparkle burst is hand-rolled in
        // FluidoKit instead.)
        .package(url: "https://github.com/EmergeTools/Pow", exact: "1.0.6"),
    ],
    targets: [
        .target(
            name: "BlaiseCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [
                // .copy keeps the python drivers byte-exact (no processing).
                .copy("Resources/whisper_driver.py"),
                .copy("Resources/notes_driver.py"),
                .copy("Resources/python_requirements.txt"),
                // C7: the C5 vocabulary fixtures bundled into the app
                // (the corrector loads from the bundle at runtime; a unit
                // test asserts byte-equality with the repo fixtures/ copies).
                // G1: the shipped user-glossary template (provisioned into the
                // data root on first launch).
                .copy("Resources/glossary_template.md"),
                .copy("Resources/stoplist_pt.txt"),
                .copy("Resources/stoplist_en.txt"),
                .copy("Resources/stoplist_user.txt"),
                .copy("Resources/stoplist_exclusions.txt"),
                .copy("Resources/br_common_names.txt"),
            ]
        ),
        .executableTarget(
            name: "BlaiseApp",
            dependencies: [
                "BlaiseCore",
                .product(name: "Pow", package: "Pow"),
            ]
        ),
        // C7 crash harness child process (scripts/c7_crash_harness.sh): runs
        // the pipeline so kill -9 at the BLAISE_CRASH_AT hook points (and one
        // real-engine timing kill) can be asserted from outside. Debug
        // tooling, never shipped in the app bundle.
        .executableTarget(
            name: "CrashRunner",
            dependencies: ["BlaiseCore"]
        ),
        .testTarget(
            name: "BlaiseCoreTests",
            dependencies: ["BlaiseCore"]
        ),
        // BlaiseApp unit tests: headless (no scene/window). Used to pin the
        // Settings-scene observation invariant (field bug 12/06) — that a
        // recording-timer state tick does not invalidate the surfaces the
        // Settings scene depends on. Depends on the executable target so the
        // @MainActor @Observable holders (CaptureStatusHolder) are reachable
        // via @testable import.
        .testTarget(
            name: "BlaiseAppTests",
            dependencies: ["BlaiseApp", "BlaiseCore"]
        ),
    ]
)
