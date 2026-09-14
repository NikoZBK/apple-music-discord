import Foundation

public enum MusicPlaybackState: String, Codable, Sendable {
  case playing
  case paused
}

public struct AppleMusicNextTrack: Equatable, Sendable {
  public let libraryID: String?
  public let title: String
  public let artist: String
  public let album: String
  public let durationMs: Int?

  public init(libraryID: String?, title: String, artist: String, album: String, durationMs: Int?) {
    self.libraryID = libraryID
    self.title = title
    self.artist = artist
    self.album = album
    self.durationMs = durationMs
  }

  public var identity: String {
    if let libraryID { return "library:\(libraryID)" }
    let fields = [title, artist, album]
    return "metadata:" + fields.map { "\($0.utf8.count):\($0)" }.joined()
  }
}

public struct AppleMusicObservation: Equatable, Sendable {
  public let libraryID: String?
  public let title: String
  public let artist: String
  public let album: String
  public let state: MusicPlaybackState
  public let positionMs: Int?
  public let durationMs: Int?
  public let playedCount: Int?
  public let observedAt: Int
  public let next: AppleMusicNextTrack?

  public init(
    libraryID: String?, title: String, artist: String, album: String,
    state: MusicPlaybackState, positionMs: Int?, durationMs: Int?,
    playedCount: Int?, observedAt: Int, next: AppleMusicNextTrack? = nil
  ) {
    self.libraryID = libraryID
    self.title = title
    self.artist = artist
    self.album = album
    self.state = state
    self.positionMs = positionMs
    self.durationMs = durationMs
    self.playedCount = playedCount
    self.observedAt = observedAt
    self.next = next
  }

  public var identity: String {
    if let libraryID { return "library:\(libraryID)" }
    let fields = [title, artist, album]
    return "metadata:" + fields.map { "\($0.utf8.count):\($0)" }.joined()
  }
}

public struct AppleMusicTrackExtras: Equatable, Sendable {
  public let artworkURL: String?
  public let externalURL: String?

  public static let none = AppleMusicTrackExtras(artworkURL: nil, externalURL: nil)

  public init(artworkURL: String?, externalURL: String?) {
    self.artworkURL = artworkURL
    self.externalURL = externalURL
  }
}

public struct AppleMusicSnapshot: Codable, Equatable, Sendable {
  public let provider: String
  public let trackID: String?
  public let catalogScope: String?
  public let song: String
  public let artist: String
  public let album: String
  public let state: MusicPlaybackState
  public let positionMs: Int?
  public let durationMs: Int?
  public let observedAt: Int
  public let artworkURL: String?
  public let externalURL: String?

  enum CodingKeys: String, CodingKey {
    case provider
    case trackID = "track_id"
    case catalogScope = "catalog_scope"
    case song, artist, album, state
    case positionMs = "position_ms"
    case durationMs = "duration_ms"
    case observedAt = "observed_at"
    case artworkURL = "artwork_url"
    case externalURL = "external_url"
  }

  public init(_ observation: AppleMusicObservation, extras: AppleMusicTrackExtras = .none) {
    provider = "apple_music"
    trackID = observation.libraryID
    catalogScope = observation.libraryID == nil ? nil : "library"
    song = observation.title
    artist = observation.artist
    album = observation.album
    state = observation.state
    positionMs = observation.positionMs
    durationMs = observation.durationMs
    observedAt = observation.observedAt
    artworkURL = extras.artworkURL
    externalURL = extras.externalURL
  }
}

public enum MusicPresenceError: Error, Equatable {
  case invalidObservation
}

public func validate(_ observation: AppleMusicObservation) throws {
  guard !observation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !observation.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        observation.libraryID == nil || !observation.libraryID!.isEmpty,
        observation.observedAt >= 0,
        observation.positionMs == nil || observation.positionMs! >= 0,
        observation.durationMs == nil || observation.durationMs! > 0,
        observation.positionMs == nil || observation.durationMs == nil
          || observation.positionMs! <= observation.durationMs! else {
    throw MusicPresenceError.invalidObservation
  }
}
