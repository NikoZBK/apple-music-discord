import Foundation
import AppleMusicDiscordCore

private enum CatalogError: Error {
  case invalidResponse
  case rejected(Int)
}

/// Resolves, per track, the Apple Music song page Music does not report each
/// second. Results are cached by track identity and found by strict catalog
/// match.
@MainActor
final class AppleMusicExtrasResolver {
  struct Configuration {
    /// Nil skips the catalog search.
    var storefront: String?
  }

  /// The outcome of one track's catalog link, with when it was reached, so a
  /// miss is cached and a failure backs off.
  private struct Entry {
    enum Outcome { case found(AppleCatalogLink.Match), missing, failed }
    var outcome: Outcome
    var at: Date
    var attempts: Int
  }

  static let failureBackoff: TimeInterval = 30
  static let cacheLimit = 400

  private let configuration: Configuration
  private let session: URLSession
  private let log: (String) -> Void
  private var links: [String: Entry] = [:]

  init(configuration: Configuration, session: URLSession = .shared,
       log: @escaping (String) -> Void) {
    self.configuration = configuration
    self.session = session
    self.log = log
  }

  func extras(for observation: AppleMusicObservation) async -> AppleMusicTrackExtras {
    await resolve(
      identity: observation.identity,
      query: AppleCatalogLink.Query(title: observation.title, artist: observation.artist,
                                    album: observation.album, durationMs: observation.durationMs)
    )
  }

  func extras(for track: AppleMusicNextTrack) async -> AppleMusicTrackExtras {
    await resolve(
      identity: track.identity,
      query: AppleCatalogLink.Query(title: track.title, artist: track.artist,
                                    album: track.album, durationMs: track.durationMs)
    )
  }

  private func resolve(identity: String, query: AppleCatalogLink.Query) async -> AppleMusicTrackExtras {
    if links.count > Self.cacheLimit { links.removeAll() }
    let now = Date()
    let match = await resolveLink(identity: identity, query: query, now: now)
    return AppleMusicTrackExtras(artworkURL: match?.artworkURL, externalURL: match?.songURL)
  }

  private func resolveLink(identity: String, query: AppleCatalogLink.Query, now: Date) async -> AppleCatalogLink.Match? {
    guard let storefront = configuration.storefront else { return nil }
    if let entry = links[identity] {
      switch entry.outcome {
      case .found(let match): return match
      case .missing: return nil
      case .failed:
        guard now.timeIntervalSince(entry.at) >= Self.failureBackoff else { return nil }
      }
    }
    let attempts = (links[identity]?.attempts ?? 0) + 1
    guard let url = AppleCatalogLink.searchURL(for: query, storefront: storefront) else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    request.cachePolicy = .reloadIgnoringLocalCacheData
    do {
      let (body, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw CatalogError.invalidResponse }
      guard (200..<300).contains(http.statusCode) else { throw CatalogError.rejected(http.statusCode) }
      if let match = AppleCatalogLink.songMatch(for: query, in: body) {
        links[identity] = Entry(outcome: .found(match), at: now, attempts: attempts)
        return match
      }
      // The catalog has no exact counterpart; a near miss is not linked.
      links[identity] = Entry(outcome: .missing, at: now, attempts: attempts)
      return nil
    } catch {
      links[identity] = Entry(outcome: .failed, at: now, attempts: attempts)
      log("catalog search \(error); retrying later")
      return nil
    }
  }
}
