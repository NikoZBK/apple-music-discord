import Foundation

/// The portion of a Discord Rich Presence activity that an Apple Music
/// companion owns. This stays in the provider-neutral core so the companion
/// does not depend on a server-side transport.
public struct DiscordPresenceActivity: Codable, Equatable, Sendable {
  public let type: Int
  public let name: String
  public let details: String
  public let state: String?
  public let detailsURL: String?
  public let timestamps: Timestamps?
  public let assets: Assets?

  public init(snapshot: AppleMusicSnapshot, largeImage: String? = nil) {
    type = 2 // Listening
    name = "Apple Music"
    details = snapshot.song
    state = snapshot.artist.isEmpty ? nil : snapshot.artist
    detailsURL = snapshot.externalURL.flatMap(AppleCatalogLink.canonicalSongURL)

    if let position = snapshot.positionMs, let duration = snapshot.durationMs,
       snapshot.state == .playing {
      let start = max(0, (snapshot.observedAt - position) / 1_000)
      let end = start + duration / 1_000
      timestamps = Timestamps(start: start, end: end)
    } else {
      timestamps = nil
    }

    if let largeImage, !largeImage.isEmpty {
      assets = Assets(largeImage: largeImage, largeText: "Apple Music")
    } else {
      assets = nil
    }
  }

  public struct Timestamps: Codable, Equatable, Sendable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
      self.start = start
      self.end = end
    }
  }

  public struct Assets: Codable, Equatable, Sendable {
    public let largeImage: String
    public let largeText: String

    public init(largeImage: String, largeText: String) {
      self.largeImage = largeImage
      self.largeText = largeText
    }

    enum CodingKeys: String, CodingKey {
      case largeImage = "large_image"
      case largeText = "large_text"
    }
  }

  enum CodingKeys: String, CodingKey {
    case type, name, details, state
    case detailsURL = "details_url"
    case timestamps, assets
  }
}

/// A SET_ACTIVITY RPC command. `activity == nil` is an explicit clear, so
/// the custom encoder preserves the null field Discord expects.
public struct DiscordSetActivityCommand: Encodable, Equatable, Sendable {
  public let nonce: String
  public let pid: Int32
  public let activity: DiscordPresenceActivity?

  public init(nonce: String, pid: Int32, activity: DiscordPresenceActivity?) {
    self.nonce = nonce
    self.pid = pid
    self.activity = activity
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode("SET_ACTIVITY", forKey: .command)
    try container.encode(nonce, forKey: .nonce)
    var args = container.nestedContainer(keyedBy: ArgsKeys.self, forKey: .args)
    try args.encode(pid, forKey: .pid)
    try args.encode(activity, forKey: .activity)
  }

  private enum CodingKeys: String, CodingKey {
    case command = "cmd"
    case nonce, args
  }

  private enum ArgsKeys: String, CodingKey {
    case pid, activity
  }
}
