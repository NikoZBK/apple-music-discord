import Foundation
import AppleMusicDiscordCore

var failures = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  if condition() { print("ok - \(message)") }
  else { failures += 1; print("not ok - \(message)") }
}

let observation = AppleMusicObservation(
  libraryID: "LIBRARY-ID", title: "Song", artist: "Artist", album: "Album",
  state: .playing, positionMs: 10_000, durationMs: 180_000,
  playedCount: 2, observedAt: 100_000
)
do { try validate(observation); expect(true, "valid observation") }
catch { expect(false, "valid observation") }

let snapshot = AppleMusicSnapshot(observation, extras: AppleMusicTrackExtras(
  artworkURL: "https://is1-ssl.mzstatic.com/image/thumb/Music/100x100bb.jpg",
  externalURL: "https://music.apple.com/us/song/song/123"
))
let activity = DiscordPresenceActivity(snapshot: snapshot, largeImage: "apple_music")
expect(activity.type == 2 && activity.name == "Apple Music" && activity.details == "Song"
       && activity.state == "Artist", "activity identifies the current song")
expect(activity.detailsURL == "https://music.apple.com/us/song/song/123"
       && activity.timestamps?.start == 90 && activity.timestamps?.end == 270,
       "activity keeps the canonical link and playback clock")
expect(activity.assets?.largeImage == "https://is1-ssl.mzstatic.com/image/thumb/Music/100x100bb.jpg"
       && activity.assets?.largeText == "Album", "activity uses the matched album artwork")

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
let activityWire = String(data: try encoder.encode(activity), encoding: .utf8)!
expect(activityWire.contains(#""details_url":"https://music.apple.com/us/song/song/123""#)
       && activityWire.contains(#""large_image":"https://is1-ssl.mzstatic.com/image/thumb/Music/100x100bb.jpg""#),
       "activity wire uses Discord field names")
let clear = DiscordSetActivityCommand(nonce: "test", pid: 42, activity: nil)
let clearWire = String(data: try encoder.encode(clear), encoding: .utf8)!
expect(clearWire.contains(#""activity":null"#) && clearWire.contains(#""cmd":"SET_ACTIVITY""#),
       "clear wire is an explicit SET_ACTIVITY null")

expect(AppleCatalogLink.canonicalSongURL("https://music.apple.com/us/song/song/123") != nil,
       "Apple song pages are admitted")
expect(AppleCatalogLink.canonicalSongURL("https://music.apple.com/us/album/song/123") == nil,
       "album pages without a song selector are rejected")
expect(AppleCatalogLink.canonicalArtworkURL("https://is1-ssl.mzstatic.com/image/thumb/Music/100x100bb.jpg") != nil,
       "Apple artwork URLs are admitted")
expect(AppleCatalogLink.canonicalArtworkURL("https://example.com/art.jpg") == nil,
       "untrusted artwork hosts are rejected")
let catalogBody = Data(#"{"resultCount":1,"results":[{"kind":"song","trackName":"Song","artistName":"Artist","collectionName":"Album","trackTimeMillis":180000,"trackViewUrl":"https://music.apple.com/us/song/song/123","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music/100x100bb.jpg"}]}"#.utf8)
let catalogMatch = AppleCatalogLink.songMatch(
  for: AppleCatalogLink.Query(title: "Song", artist: "Artist", album: "Album", durationMs: 180_000),
  in: catalogBody
)
expect(catalogMatch?.songURL == "https://music.apple.com/us/song/song/123"
       && catalogMatch?.artworkURL == "https://is1-ssl.mzstatic.com/image/thumb/Music/100x100bb.jpg",
       "catalog matches carry exact album artwork")

exit(failures == 0 ? 0 : 1)
