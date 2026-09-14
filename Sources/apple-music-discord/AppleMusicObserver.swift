import Foundation
import AppleMusicDiscordCore

enum AppleMusicRead {
  case silent
  case observation(AppleMusicObservation)
}

/// What Music says comes next, and on what basis, so the reading is reused
/// while the basis holds rather than re-walked every second.
struct AppleMusicNextReading {
  enum Mode: String { case playlist, album }
  let key: String
  let mode: Mode
  let track: AppleMusicNextTrack?
  let readAt: Date
}

@MainActor
final class AppleMusicObserver {
  /// The once-a-second read: state, position, identity, titles, length,
  /// play count, and the shuffle and repeat settings the next-track reading
  /// depends on.
  private static let source = """
    if application id "com.apple.Music" is not running then return {"silent"}
    tell application id "com.apple.Music"
      set stateText to player state as text
      if stateText is "stopped" then return {"silent"}
      set positionText to player position as text
      set currentItem to current track
      set persistentText to ""
      try
        set persistentText to persistent ID of currentItem as text
      end try
      if persistentText is "" then
        try
          set persistentText to database ID of currentItem as text
        end try
      end if
      set titleText to name of currentItem as text
      set artistText to artist of currentItem as text
      set albumText to album of currentItem as text
      set durationText to ""
      try
        set durationText to duration of currentItem as text
      end try
      set playedText to ""
      try
        set playedText to played count of currentItem as text
      end try
      set shuffleText to "unknown"
      set repeatText to "unknown"
      try
        set shuffleText to shuffle enabled as text
        set repeatText to song repeat as text
      end try
      return {stateText, positionText, persistentText, titleText, artistText, albumText, durationText, playedText, shuffleText, repeatText}
    end tell
    """

  /// What follows the current track, read only when Music plays in order:
  /// shuffle off and repeat not pinned to this track. Two cases:
  ///
  /// - Music plays a playlist: the entry after the current one, wrapping
  ///   under repeat all. The current track must be found at its index in
  ///   that playlist, or by its persistent ID.
  /// - Music plays the library itself (the Library or Music playlist, as
  ///   when an album is played from the Albums view): the album is the
  ///   playlist. The next track is the one after the current on the same
  ///   album by the same album artist, in disc and track order, wrapping
  ///   under repeat all. Without usable numbers nothing is said.
  ///
  /// The basis (track, shuffle, repeat) is returned so the reading can be
  /// cached against it.
  private static let nextSource = """
    if application id "com.apple.Music" is not running then return {"silent"}
    tell application id "com.apple.Music"
      if (player state as text) is "stopped" then return {"silent"}
      set currentItem to current track
      set persistentText to ""
      try
        set persistentText to persistent ID of currentItem as text
      end try
      set shuffleText to shuffle enabled as text
      set repeatText to song repeat as text
      set modeText to "playlist"
      set nextFlag to "none"
      set nextID to ""
      set nextTitle to ""
      set nextArtist to ""
      set nextAlbum to ""
      set nextDuration to ""
      try
        if (shuffle enabled is false) and (song repeat is not one) then
          set thePlaylist to current playlist
          set kindText to "none"
          try
            set kindText to special kind of thePlaylist as text
          end try
          if kindText is "Library" or kindText is "Music" then
            set modeText to "album"
            set albumText to album of currentItem as text
            set headText to ""
            try
              set headText to album artist of currentItem as text
            end try
            if headText is "" then set headText to artist of currentItem as text
            if albumText is not "" and persistentText is not "" then
              set trackIDs to persistent ID of (every track of thePlaylist whose album is albumText)
              set trackHeads to album artist of (every track of thePlaylist whose album is albumText)
              set trackArtists to artist of (every track of thePlaylist whose album is albumText)
              set trackDiscs to disc number of (every track of thePlaylist whose album is albumText)
              set trackNumbers to track number of (every track of thePlaylist whose album is albumText)
              set currentKey to 0
              repeat with i from 1 to count of trackIDs
                if (item i of trackIDs as text) is persistentText then
                  set currentKey to (item i of trackDiscs) * 10000 + (item i of trackNumbers)
                end if
              end repeat
              set nextIndex to 0
              set nextKey to 0
              set firstIndex to 0
              set firstKey to 0
              if currentKey > 0 then
                repeat with i from 1 to count of trackIDs
                  set candidateHead to item i of trackHeads as text
                  if candidateHead is "" then set candidateHead to item i of trackArtists as text
                  if candidateHead is headText and (item i of trackIDs as text) is not persistentText then
                    set candidateKey to (item i of trackDiscs) * 10000 + (item i of trackNumbers)
                    if candidateKey > currentKey and (nextIndex is 0 or candidateKey < nextKey) then
                      set nextIndex to i
                      set nextKey to candidateKey
                    end if
                    if candidateKey > 0 and (firstIndex is 0 or candidateKey < firstKey) then
                      set firstIndex to i
                      set firstKey to candidateKey
                    end if
                  end if
                end repeat
              end if
              if nextIndex is 0 and song repeat is all and firstIndex > 0 and firstKey < currentKey then set nextIndex to firstIndex
              if nextIndex > 0 then
                set nextItem to item 1 of (every track of thePlaylist whose persistent ID is (item nextIndex of trackIDs))
                set nextID to item nextIndex of trackIDs as text
                set nextTitle to name of nextItem as text
                set nextArtist to item nextIndex of trackArtists as text
                set nextAlbum to albumText
                try
                  set nextDuration to duration of nextItem as text
                end try
                set nextFlag to "next"
              end if
            end if
          else
            set trackCount to count of tracks of thePlaylist
            set currentIndex to 0
            try
              set candidate to index of currentItem
              if candidate ≥ 1 and candidate ≤ trackCount then
                if (persistent ID of track candidate of thePlaylist as text) is persistentText then set currentIndex to candidate
              end if
            end try
            if currentIndex is 0 and persistentText is not "" then
              set matches to (tracks of thePlaylist whose persistent ID is persistentText)
              if (count of matches) ≥ 1 then set currentIndex to index of item 1 of matches
            end if
            if currentIndex ≥ 1 then
              set nextIndex to currentIndex + 1
              if nextIndex > trackCount and song repeat is all then set nextIndex to 1
              if nextIndex ≤ trackCount and nextIndex is not currentIndex then
                set nextItem to track nextIndex of thePlaylist
                try
                  set nextID to persistent ID of nextItem as text
                end try
                set nextTitle to name of nextItem as text
                set nextArtist to artist of nextItem as text
                set nextAlbum to album of nextItem as text
                try
                  set nextDuration to duration of nextItem as text
                end try
                set nextFlag to "next"
              end if
            end if
          end if
        end if
      end try
      return {nextFlag, modeText, persistentText, shuffleText, repeatText, nextID, nextTitle, nextArtist, nextAlbum, nextDuration}
    end tell
    """

  /// The next-track reading is reused while its basis holds, and re-read
  /// this often regardless, so a playlist edit shows up.
  static let nextReadingLifetime: TimeInterval = 30

  private let script: NSAppleScript
  private let nextScript: NSAppleScript
  private var lastNext: AppleMusicNextReading?

  init() throws {
    script = try Self.compile(Self.source)
    nextScript = try Self.compile(Self.nextSource)
  }

  private static func compile(_ source: String) throws -> NSAppleScript {
    guard let script = NSAppleScript(source: source) else {
      throw ObserverError.compile("could not create AppleScript")
    }
    var details: NSDictionary?
    guard script.compileAndReturnError(&details) else {
      throw ObserverError.compile(details?[NSAppleScript.errorMessage] as? String ?? "unknown error")
    }
    return script
  }

  private static func run(_ script: NSAppleScript) throws -> NSAppleEventDescriptor {
    var details: NSDictionary?
    let result = script.executeAndReturnError(&details)
    if let details {
      let code = details[NSAppleScript.errorNumber] as? Int ?? 0
      let message = details[NSAppleScript.errorMessage] as? String ?? "unknown error"
      throw ObserverError.appleEvent(code, message)
    }
    return result
  }

  private static func strings(_ result: NSAppleEventDescriptor) -> [String] {
    guard result.numberOfItems > 0 else { return [] }
    return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
  }

  func read() throws -> AppleMusicRead {
    let before = Date()
    let result = try Self.run(script)
    let after = Date()
    let fields = Self.strings(result)
    if fields == ["silent"] { return .silent }
    guard fields.count == 10,
          let state = Self.state(fields[0]),
          let position = Self.milliseconds(fields[1]) else {
      throw ObserverError.invalidResponse
    }
    let midpoint = before.timeIntervalSince1970 + after.timeIntervalSince(before) / 2
    let duration = Self.milliseconds(fields[6])
    // Music can report its final position a few milliseconds beyond its
    // rounded duration. The public contract requires position <= duration.
    let boundedPosition = duration.map { min(position, $0) } ?? position
    let libraryID = fields[2].isEmpty ? nil : fields[2]
    let basis = [libraryID ?? "\(fields[3])\u{0}\(fields[4])\u{0}\(fields[5])", fields[8], fields[9]].joined(separator: "|")
    let next = try nextTrack(basis: basis, now: after)
    let observation = AppleMusicObservation(
      libraryID: libraryID,
      title: fields[3], artist: fields[4], album: fields[5], state: state,
      positionMs: boundedPosition, durationMs: duration,
      playedCount: Int(fields[7]), observedAt: Int((midpoint * 1000).rounded()), next: next
    )
    try validate(observation)
    return .observation(observation)
  }

  /// The last next-track reading, for the probe's report of its basis.
  var lastNextReading: AppleMusicNextReading? { lastNext }

  private func nextTrack(basis: String, now: Date) throws -> AppleMusicNextTrack? {
    if let lastNext, lastNext.key == basis, now.timeIntervalSince(lastNext.readAt) < Self.nextReadingLifetime {
      return lastNext.track
    }
    let fields: [String]
    do {
      fields = Self.strings(try Self.run(nextScript))
    } catch {
      // The playback read succeeded, so this is Music balking at the walk
      // (a playlist it will not enumerate, say): nothing is next for now,
      // and the walk is not retried every second.
      lastNext = AppleMusicNextReading(key: basis, mode: .playlist, track: nil, readAt: now)
      return nil
    }
    if fields == ["silent"] { return nil }
    guard fields.count == 10, let mode = AppleMusicNextReading.Mode(rawValue: fields[1]) else {
      throw ObserverError.invalidResponse
    }
    let track = fields[0] == "next" ? AppleMusicNextTrack(
      libraryID: fields[5].isEmpty ? nil : fields[5], title: fields[6], artist: fields[7],
      album: fields[8], durationMs: Self.milliseconds(fields[9])
    ) : nil
    // Cached under the basis Music reported while walking, which is the
    // per-second basis unless the track changed between the two reads; a
    // mismatch just means the next tick walks again.
    let reportedBasis = [fields[2].isEmpty ? basis.split(separator: "|").first.map(String.init) ?? "" : fields[2],
                         fields[3], fields[4]].joined(separator: "|")
    lastNext = AppleMusicNextReading(key: reportedBasis, mode: mode, track: track, readAt: now)
    return reportedBasis == basis ? track : nil
  }

  private static func state(_ value: String) -> MusicPlaybackState? {
    switch value {
    case "playing", "fast forwarding", "rewinding": .playing
    case "paused": .paused
    default: nil
    }
  }

  private static func milliseconds(_ value: String) -> Int? {
    guard !value.isEmpty,
          let seconds = Double(value.replacingOccurrences(of: ",", with: ".")),
          seconds.isFinite, seconds >= 0 else { return nil }
    let milliseconds = seconds * 1000
    guard milliseconds <= Double(Int.max) else { return nil }
    return Int(milliseconds.rounded())
  }
}

enum ObserverError: Error, CustomStringConvertible {
  case compile(String)
  case appleEvent(Int, String)
  case invalidResponse

  var description: String {
    switch self {
    case .compile(let message): "cannot compile Music observer: \(message)"
    case .appleEvent(let code, let message): "Music observation failed (\(code)): \(message)"
    case .invalidResponse: "Music returned an invalid observation"
    }
  }

  var permissionDenied: Bool {
    if case .appleEvent(-1743, _) = self { return true }
    return false
  }
}
