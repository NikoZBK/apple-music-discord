import Foundation

/// The Apple Music song page for a library track, found the only way Music's
/// scripting allows: it exposes no catalog id, so the helper asks Apple's
/// public catalog search for the title and takes a result only when title,
/// album and length agree and the artist names overlap. A near miss is no
/// link, never a guess; the page shows nothing rather than the wrong song.
public enum AppleCatalogLink {
  /// Lengths agree within this much: catalog and library durations differ
  /// by rounding, editions by seconds.
  public static let durationTolerance = 2_500

  /// The storefront the search runs against: the Mac's region, or `us`.
  public static func defaultStorefront(_ locale: Locale = .current) -> String {
    let region = locale.region?.identifier.lowercased() ?? ""
    return region.count == 2 && region.allSatisfy(\.isLetter) ? region : "us"
  }

  /// Apple's search for a song by title and artist, limited to songs of the
  /// given storefront.
  public static func searchURL(for query: Query, storefront: String) -> URL? {
    var components = URLComponents(string: "https://itunes.apple.com/search")
    let term = [query.title, query.artist].joined(separator: " ")
    components?.queryItems = [
      URLQueryItem(name: "term", value: term),
      URLQueryItem(name: "media", value: "music"),
      URLQueryItem(name: "entity", value: "song"),
      URLQueryItem(name: "limit", value: "25"),
      URLQueryItem(name: "country", value: storefront),
    ]
    return components?.url
  }

  /// The song page among the search answer's results, or nil.
  public static func songPage(for query: Query, in body: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let results = object["results"] as? [[String: Any]] else { return nil }
    return songPage(for: query, among: results.compactMap(Candidate.init))
  }

  /// The strict match: same title, same album when the library names one,
  /// artist names overlapping, and lengths within tolerance when both are
  /// known. The closest length wins; ties keep Apple's own ranking.
  public static func songPage(for query: Query, among candidates: [Candidate]) -> String? {
    let title = fold(query.title)
    let album = query.album.map(fold).flatMap { $0.isEmpty ? nil : $0 }
    let artist = fold(query.artist)
    guard !title.isEmpty, !artist.isEmpty else { return nil }
    var best: (distance: Int, url: String)?
    for candidate in candidates {
      guard candidate.kind == "song", fold(candidate.title) == title else { continue }
      if let album, fold(candidate.album) != album { continue }
      let candidateArtist = fold(candidate.artist)
      guard candidateArtist.contains(artist) || artist.contains(candidateArtist) else { continue }
      var distance = 0
      if let length = query.durationMs, let candidateLength = candidate.durationMs {
        distance = abs(length - candidateLength)
        guard distance <= durationTolerance else { continue }
      }
      guard let url = canonicalSongURL(candidate.url) else { continue }
      if best.map({ distance < $0.distance }) ?? true { best = (distance, url) }
    }
    return best?.url
  }

  /// Apple's `trackViewUrl` reduced to the song selector alone, in the two
  /// canonical shapes: an album page with `?i=<song>` or a song page.
  public static func canonicalSongURL(_ url: String) -> String? {
    guard url.count <= 2048, let components = URLComponents(string: url),
          components.scheme == "https", components.host == "music.apple.com", components.port == nil,
          components.user == nil, components.password == nil else { return nil }
    let parts = components.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
    guard parts.count == 4, let storefront = parts.first, storefront.count == 2,
          storefront.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) else { return nil }
    let slug = parts[parts.startIndex + 2], id = parts[parts.startIndex + 3]
    guard isSlug(slug), isDigits(id) else { return nil }
    switch parts[parts.startIndex + 1] {
    case "album":
      guard let song = components.queryItems?.first(where: { $0.name == "i" })?.value,
            isDigits(song[...]) else { return nil }
      return "https://music.apple.com/\(storefront)/album/\(slug)/\(id)?i=\(song)"
    case "song":
      return "https://music.apple.com/\(storefront)/song/\(slug)/\(id)"
    default:
      return nil
    }
  }

  private static func isSlug(_ value: Substring) -> Bool {
    !value.isEmpty && value.count <= 200 && value.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
      && value.first != "-"
  }

  private static func isDigits(_ value: Substring) -> Bool {
    !value.isEmpty && value.count <= 20 && value.allSatisfy { $0.isASCII && $0.isNumber }
  }

  /// Names compared without case, accents, width or stray spacing.
  static func fold(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  public struct Query: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String?
    public let durationMs: Int?

    public init(title: String, artist: String, album: String?, durationMs: Int?) {
      self.title = title
      self.artist = artist
      self.album = album
      self.durationMs = durationMs
    }
  }

  /// One search result, as far as the match reads it.
  public struct Candidate: Equatable, Sendable {
    public let kind: String
    public let title: String
    public let artist: String
    public let album: String
    public let durationMs: Int?
    public let url: String

    public init(kind: String = "song", title: String, artist: String, album: String, durationMs: Int?, url: String) {
      self.kind = kind
      self.title = title
      self.artist = artist
      self.album = album
      self.durationMs = durationMs
      self.url = url
    }

    public init?(_ result: [String: Any]) {
      guard let title = result["trackName"] as? String, let artist = result["artistName"] as? String,
            let url = result["trackViewUrl"] as? String else { return nil }
      self.init(
        kind: result["kind"] as? String ?? "song", title: title, artist: artist,
        album: result["collectionName"] as? String ?? "",
        durationMs: (result["trackTimeMillis"] as? NSNumber)?.intValue, url: url
      )
    }
  }
}
