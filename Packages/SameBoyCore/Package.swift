// swift-tools-version: 5.9
import PackageDescription

// SameBoy feature flags. These must match the defines in
// Sources/SameBoyCore/include/SameBoyCore.h so that the C sources and the
// Swift-facing headers agree on the layout of GB_gameboy_t.
let featureDefines: [CSetting] = [
    .define("GB_DISABLE_DEBUGGER"),
    .define("GB_DISABLE_CHEATS"),
    .define("GB_DISABLE_REWIND"),
]

let package = Package(
    name: "SameBoyCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SameBoyCore", targets: ["SameBoyCore"]),
    ],
    targets: [
        .target(
            name: "SameBoyCore",
            path: "Sources/SameBoyCore",
            // `Core` is a symlink to Vendor/SameBoy/Core (git submodule).
            // Files below are only needed for the debugger, cheats and rewind,
            // which are disabled for this front end.
            exclude: [
                "Core/debugger.c",
                "Core/sm83_disassembler.c",
                "Core/symbol_hash.c",
                "Core/cheats.c",
                "Core/cheat_search.c",
                "Core/rewind.c",
                "Core/graphics",
            ],
            sources: ["Core"],
            publicHeadersPath: "include",
            cSettings: featureDefines + [
                .define("GB_INTERNAL"),
                .define("_GNU_SOURCE"),
                .define("GB_VERSION", to: "\"1.0.4\""),
                .define("GB_COPYRIGHT_YEAR", to: "\"2026\""),
                .unsafeFlags(["-std=gnu11", "-Wno-everything"]),
            ]
        ),
    ]
)
