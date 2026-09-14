// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "apple-music-discord",
  platforms: [.macOS("14.2")],
  products: [
    .executable(name: "apple-music-discord", targets: ["apple-music-discord"]),
  ],
  targets: [
    .target(name: "AppleMusicDiscordCore"),
    .executableTarget(
      name: "apple-music-discord",
      dependencies: ["AppleMusicDiscordCore"],
      exclude: ["Info.plist"],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist", "-Xlinker", "Sources/apple-music-discord/Info.plist",
        ])
      ]
    ),
    .executableTarget(
      name: "apple-music-discord-check",
      dependencies: ["AppleMusicDiscordCore"]
    ),
  ]
)
