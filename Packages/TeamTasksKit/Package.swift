// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TeamTasksKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TeamTasksCore", targets: ["TeamTasksCore"]),
        .library(name: "TeamTasksMocks", targets: ["TeamTasksMocks"]),
        .library(name: "TeamTasksSupabase", targets: ["TeamTasksSupabase"]),
    ],
    dependencies: [
        // v3 is still beta (requires Swift 6.2 / Xcode 26); stay on the stable v2 line.
        .package(url: "https://github.com/supabase/supabase-swift.git", "2.55.0"..<"3.0.0"),
    ],
    targets: [
        // Pure logic: models, service protocols, view models. No SwiftUI/UIKit/Supabase.
        .target(name: "TeamTasksCore"),
        // In-memory backend implementing the same permission matrix as the SQL (previews, UI tests, unit tests).
        .target(name: "TeamTasksMocks", dependencies: ["TeamTasksCore"]),
        // Backend-agnostic contract scenarios (docs/CONTRACTS.md), run against the mocks and the Supabase adapters.
        .target(name: "TeamTasksContract", dependencies: ["TeamTasksCore"]),
        // Supabase implementations of the Core service protocols.
        .target(
            name: "TeamTasksSupabase",
            dependencies: [
                "TeamTasksCore",
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(name: "TeamTasksCoreTests", dependencies: ["TeamTasksCore", "TeamTasksMocks"]),
        .testTarget(
            name: "TeamTasksMocksTests",
            dependencies: ["TeamTasksMocks", "TeamTasksContract", "TeamTasksCore"]
        ),
        .testTarget(
            name: "TeamTasksSupabaseTests",
            dependencies: ["TeamTasksSupabase", "TeamTasksCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
