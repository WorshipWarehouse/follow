// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "FollowCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "FollowCore", targets: ["FollowCore"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20")],
    targets: [
        .target(name: "FollowCore", dependencies: ["ZIPFoundation"], path: "Follow", exclude: ["FollowApp.swift", "Narrator.swift", "PaginatedReader.swift", "ReadingTools.swift", "Info.plist", "Follow.entitlements", "Assets.xcassets"], sources: ["Models.swift", "EPUBImporter.swift"]),
        .testTarget(name: "FollowCoreTests", dependencies: ["FollowCore"], path: "CoreTests", resources: [.copy("Sample.epub")])
    ]
)
