// swift-tools-version:5.3
// When used via SPM the minimum Swift version is 5.3 because we need support for resources

import Foundation
import PackageDescription

let package = Package(
    name: "StreamChatSwiftUI",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v14), .macOS(.v11)
    ],
    products: [
        .library(
            name: "StreamChatSwiftUI",
            targets: ["StreamChatSwiftUI"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/Vah-Vah/stream-chat-swift.git", .branch("vahvah/enhancement/make-chat-channel-init-public")),        
        .package(url: "https://github.com/kean/Nuke.git", from: "10.0.0"),
        .package(url: "https://github.com/kean/NukeUI.git", from: "0.7.0")
    ],
    targets: [
        .target(
            name: "StreamChatSwiftUI",
            dependencies: [.product(name: "StreamChat", package: "stream-chat-swift"), "Nuke", "NukeUI"],
            exclude: ["README.md", "Info.plist", "Generated/L10n_template.stencil"],
            resources: [.process("Resources")]
        )
    ]
)
