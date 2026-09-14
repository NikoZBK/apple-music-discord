# Apple Music Discord Rich Presence

A small macOS companion that reads the track currently playing in the native
Music app and publishes it as Discord Rich Presence.

It uses Apple's local Apple-event dictionary for metadata and Discord's local
IPC endpoint for Rich Presence. It does not capture audio, use a Discord user
token, run a bot, or send playback data to a server.

## What it shows

- `Listening to Apple Music`
- Current song and artist
- Elapsed and remaining time when Music reports timing
- A strict Apple Music song-page link when the catalog match is exact
- An optional Rich Presence image asset
- An explicit clear when playback stops

The companion only clears the activity created by its own Discord application.
If Discord Desktop is closed, it reconnects when the next update is due.

## Requirements

- macOS 14.2 or newer
- Swift 5.10+ and the macOS Command Line Tools
- Apple Music installed and running
- Discord Desktop installed and signed in
- A Discord Developer Application ID

Create an application in the [Discord Developer Portal](https://discord.com/developers/applications).
Rich Presence is sent through Discord's [local RPC interface](https://docs.discord.com/developers/topics/rpc),
which requires the desktop client to be running. Upload an optional image in
the application's Rich Presence assets and use its key in the environment file.
On macOS, Discord usually creates its IPC socket under `$TMPDIR`; the companion
checks that runtime directory as well as `/tmp` automatically.

## Build and run

```sh
swift build -c release
export APPLE_MUSIC_DISCORD_CLIENT_ID=YOUR-DISCORD-APPLICATION-ID
export APPLE_MUSIC_DISCORD_LARGE_IMAGE=apple_music  # optional
.build/release/apple-music-discord
```

The first run may prompt for **Automation** permission for Music. Grant it in
System Settings → Privacy & Security → Automation.

To read Music once without publishing:

```sh
.build/release/apple-music-discord --probe
```

The default storefront comes from the Mac's locale. Override it with
`APPLE_MUSIC_DISCORD_STOREFRONT=us`, or set
`APPLE_MUSIC_DISCORD_LINKS=off` to skip catalog lookup. A song link is kept
only when title, artist, album, duration, and the canonical Apple URL agree;
near matches stay unlinked.

## Run at login

```sh
swift build -c release
mkdir -p ~/.local/bin ~/.config/apple-music-discord ~/Library/Logs
cp .build/release/apple-music-discord ~/.local/bin/
cp launchd/apple-music-discord-run ~/.local/bin/
cp launchd/env.example ~/.config/apple-music-discord/env
chmod 700 ~/.local/bin/apple-music-discord-run
chmod 600 ~/.config/apple-music-discord/env
$EDITOR ~/.config/apple-music-discord/env
sed "s|/Users/YOU|$HOME|g" launchd/dev.apple-music-discord.plist \
  > ~/Library/LaunchAgents/dev.apple-music-discord.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.apple-music-discord.plist
tail -f ~/Library/Logs/apple-music-discord.log
```

Stop it with:

```sh
launchctl bootout gui/$(id -u)/dev.apple-music-discord
```

## Development checks

```sh
swift run apple-music-discord-check
swift build -c release
```

The check target validates observation bounds, activity serialization,
timestamps, canonical Apple URLs, and explicit Discord clears without needing
Music or Discord to be running.

## Privacy and scope

The integration is local by design. Track metadata is sent only to the local
Discord client. The Apple catalog lookup sends title and artist to Apple's
public search endpoint only when links are enabled. No credentials are stored
by this program; keep the environment file mode `600`.

Contributions that add another music source should keep source observation,
normalized activity construction, and the Discord IPC transport separate. Do
not add service tokens, server-side relays, or account scraping to this
repository.

## License

MIT. See [LICENSE](LICENSE).
