import Foundation
import AppleMusicDiscordCore

func log(_ message: String) {
  FileHandle.standardError.write("[apple-music-discord] \(message)\n".data(using: .utf8)!)
}

@main
@MainActor
struct AppleMusicDiscordMain {
  static func main() async {
    let arguments = Set(CommandLine.arguments.dropFirst())
    if arguments.contains("--help") || arguments.contains("-h") {
      print("""
      usage: apple-music-discord [--probe]

        --probe  read Music once and print the local observation; do not publish

      environment:
        APPLE_MUSIC_DISCORD_CLIENT_ID       Discord Developer Application ID
        APPLE_MUSIC_DISCORD_LARGE_IMAGE     optional uploaded asset key
        APPLE_MUSIC_DISCORD_STOREFRONT      optional two-letter Apple storefront
        APPLE_MUSIC_DISCORD_LINKS           set to off to skip song-page lookup
      """)
      return
    }
    guard arguments.isSubset(of: ["--probe"]) else {
      log("unknown argument")
      exit(2)
    }

    do {
      let observer = try AppleMusicObserver()
      let environment = ProcessInfo.processInfo.environment
      let storefront: String? = environment["APPLE_MUSIC_DISCORD_LINKS"]?.lowercased() == "off" ? nil
        : (environment["APPLE_MUSIC_DISCORD_STOREFRONT"].map { $0.lowercased() } ?? AppleCatalogLink.defaultStorefront())

      if arguments.contains("--probe") {
        switch try observer.read() {
        case .silent: log("Music is not playing")
        case .observation(let value):
          log("Music: \(value.state.rawValue), \(value.title) — \(value.artist), position \(value.positionMs.map(String.init) ?? "unknown") ms")
          let resolver = AppleMusicExtrasResolver(
            configuration: .init(storefront: storefront), log: log
          )
          let extras = await resolver.extras(for: value)
          log(extras.externalURL.map { "song page: \($0)" } ?? "song page: no exact catalog match")
          log(extras.artworkURL.map { "album art: \($0)" } ?? "album art: no exact catalog match")
        }
        return
      }

      guard let clientID = environment["APPLE_MUSIC_DISCORD_CLIENT_ID"] else {
        throw DiscordRPCError.invalidClientID
      }
      let discord = try DiscordRichPresencePublisher(
        clientID: clientID,
        largeImage: environment["APPLE_MUSIC_DISCORD_LARGE_IMAGE"]
      )
      let resolver = AppleMusicExtrasResolver(
        configuration: .init(storefront: storefront), log: log
      )
      var lastIdentity: String?
      var lastState: MusicPlaybackState?
      var lastPosition: Int?
      var lastExternalURL: String?
      var lastArtworkURL: String?
      var lastPublishedAt = Date.distantPast
      var lastObserverErrorAt = Date.distantPast
      var lastDiscordErrorAt = Date.distantPast
      log("observer ready; waiting for Apple Music")

      while !Task.isCancelled {
        let now = Date()
        do {
          switch try observer.read() {
          case .observation(let observation):
            let extras = await resolver.extras(for: observation)
            let seeked = observation.identity == lastIdentity
              && observation.positionMs != nil && lastPosition != nil
              && abs(observation.positionMs! - lastPosition!) > 2_000
            let changed = observation.identity != lastIdentity
              || observation.state != lastState
              || seeked
              || extras.externalURL != lastExternalURL
              || extras.artworkURL != lastArtworkURL
              || now.timeIntervalSince(lastPublishedAt) >= 15
            if changed && (observation.state == .playing || discord.active) {
              do {
                try discord.publish(snapshot: AppleMusicSnapshot(observation, extras: extras))
                lastPublishedAt = now
                lastExternalURL = extras.externalURL
                lastArtworkURL = extras.artworkURL
                log("published \(observation.title) — \(observation.artist)")
              } catch {
                if now.timeIntervalSince(lastDiscordErrorAt) >= 30 {
                  lastDiscordErrorAt = now
                  log("Discord Rich Presence: \(error)")
                }
              }
            }
            lastIdentity = observation.identity
            lastState = observation.state
            lastPosition = observation.positionMs
          case .silent:
            if discord.active {
              do {
                try discord.clear()
                log("cleared Discord Rich Presence")
              } catch {
                if now.timeIntervalSince(lastDiscordErrorAt) >= 30 {
                  lastDiscordErrorAt = now
                  log("Discord Rich Presence: \(error)")
                }
              }
            }
            lastIdentity = nil
            lastState = nil
            lastPosition = nil
            lastExternalURL = nil
            lastArtworkURL = nil
        }
        } catch let error as ObserverError {
          if error.permissionDenied || now.timeIntervalSince(lastObserverErrorAt) >= 60 {
            log(error.description + (error.permissionDenied
              ? " (System Settings › Privacy & Security › Automation)" : ""))
            lastObserverErrorAt = now
          }
        } catch {
          log("\(error)")
        }
        try? await Task.sleep(for: .seconds(1))
      }
    } catch {
      log("\(error)")
      exit(2)
    }
  }
}
