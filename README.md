# Apple Music Discord Rich Presence

A small macOS companion that reads the track playing in the native Apple Music
app and publishes it as Discord Rich Presence.

It uses Apple Events to read Music locally and Discord's local IPC transport to
set the activity. It does not capture audio, run a Discord bot, use a Discord
user token, or send playback through a server.

## What it does

When Apple Music is playing, the companion publishes:

- **Listening to Apple Music** as the activity
- The current song and artist
- Elapsed and remaining playback time when Music reports timing
- A clickable Apple Music song page when an exact catalog match is found
- The matching album artwork as the Rich Presence image

When playback stops, it sends an explicit clear for the activity owned by this
application. If Discord Desktop is closed, the companion keeps observing Music
and reconnects to Discord when the next update is due.

## Architecture

```text
Apple Music.app
    │ Apple Events
    ▼
Apple Music observer
    │ optional exact catalog enrichment
    ▼
Discord Rich Presence over local IPC
    │
    ▼
Discord Desktop profile activity
```

The Discord connection is local. The companion does not need a web server,
Discord bot, gateway connection, OAuth token, or Discord server installation.
Discord's [RPC interface](https://docs.discord.com/developers/topics/rpc)
requires the native desktop client to be running.

## Requirements

- macOS 14.2 or newer
- Swift 5.10 or newer and the macOS Command Line Tools
- Apple Music installed and running
- Discord Desktop installed and signed in
- A Discord Developer Application

Create an application in the [Discord Developer Portal](https://discord.com/developers/applications).
On **General Information**, copy **Application ID**. That numeric value is the
only Discord value this companion needs. Do not create a bot token or configure
OAuth for this integration.

On macOS, Discord usually creates its IPC socket under `$TMPDIR`. The
companion checks that directory, `/tmp`, and the other standard runtime paths
automatically.

## Build and run

Clone the repository and build the release executable:

```sh
git clone https://github.com/NikoZBK/apple-music-discord.git
cd apple-music-discord
swift build -c release
```

Set the Application ID in the current terminal and start the companion:

```sh
export APPLE_MUSIC_DISCORD_CLIENT_ID=YOUR-DISCORD-APPLICATION-ID
.build/release/apple-music-discord
```

Keep Discord Desktop open. The first run may ask for permission to control
Music. Grant it in **System Settings → Privacy & Security → Automation**.

### Optional configuration

```sh
# Uploaded Discord asset key used only when no exact Apple artwork is found.
export APPLE_MUSIC_DISCORD_LARGE_IMAGE=apple_music

# Override the Apple storefront used for catalog lookup.
export APPLE_MUSIC_DISCORD_STOREFRONT=us

# Disable Apple catalog lookup, song links, and dynamic album artwork.
export APPLE_MUSIC_DISCORD_LINKS=off
```

Catalog enrichment is enabled by default. It sends the current title and
artist to Apple's public search endpoint, then keeps a result only when the
title, artist, album, duration, and canonical song URL agree. Near matches are
discarded. Album artwork is taken only from that same exact match.

### Probe Music without publishing

The probe reads Apple Music once and prints the observed track, song-page match,
and album-art match without contacting Discord:

```sh
.build/release/apple-music-discord --probe
```

## Run automatically at login

The repository includes a launchd wrapper. It keeps the companion in the
background, starts it at login, and restarts it if it exits.

```sh
swift build -c release
mkdir -p ~/.local/bin ~/.config/apple-music-discord ~/Library/Logs ~/Library/LaunchAgents
cp .build/release/apple-music-discord ~/.local/bin/
cp launchd/apple-music-discord-run ~/.local/bin/
cp launchd/env.example ~/.config/apple-music-discord/env
chmod 700 ~/.local/bin/apple-music-discord-run
chmod 600 ~/.config/apple-music-discord/env
```

Edit the environment file and replace the placeholder with your Application ID:

```sh
$EDITOR ~/.config/apple-music-discord/env
```

Install and start the login agent:

```sh
sed "s|/Users/YOU|$HOME|g" launchd/dev.apple-music-discord.plist \
  > ~/Library/LaunchAgents/dev.apple-music-discord.plist
launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/dev.apple-music-discord.plist
```

Watch its log:

```sh
tail -f ~/Library/Logs/apple-music-discord.log
```

Stop the agent:

```sh
launchctl bootout gui/$(id -u)/dev.apple-music-discord
```

If you edit the environment file while the agent is running, restart it:

```sh
launchctl kickstart -k gui/$(id -u)/dev.apple-music-discord
```

## Troubleshooting

### `Discord RPC socket error: No such file or directory`

Make sure the native Discord application is open. A browser tab at
`discord.com` does not expose the local RPC socket. Check the macOS runtime
directory directly:

```sh
ls -la "$TMPDIR"/discord-ipc-*
```

Then rebuild or restart the companion. The socket is normally named
`discord-ipc-0`.

### Music is not detected

Run the probe and check Automation permission:

```sh
.build/release/apple-music-discord --probe
```

Open **System Settings → Privacy & Security → Automation** and allow the
companion to control Music. The companion reads the native Music app, not
Apple Music in a browser.

### The song appears without a link or cover

Catalog enrichment may be disabled, or Apple's result may not be an exact
match. Confirm that `APPLE_MUSIC_DISCORD_LINKS` is not set to `off`, then run
the probe. A missing match is intentional: the companion does not guess a song
page or artwork for a near match.

### The activity is not visible in Discord

Confirm that Discord Desktop is running and that **User Settings → Activity
Privacy → Display current activity as a status message** is enabled. Check the
companion log for a `published` line.

## Development

The core package contains the provider-neutral Apple Music model, strict Apple
catalog matching, and Discord activity serialization. The executable target
contains the macOS Apple Events observer and Discord IPC client. The check
target exercises the wire payload without requiring Music or Discord to be
running.

Run the checks with:

```sh
swift run apple-music-discord-check
swift build -c release
git diff --check
```

Contributions that add another music source should keep source observation,
normalized activity construction, and Discord IPC transport separate. Do not
add service tokens, server-side relays, or account scraping to this repository.

## Privacy and scope

The companion observes playback locally and sends the activity to the local
Discord client. When catalog enrichment is enabled, only the current title and
artist are sent to Apple's public search endpoint. The matched artwork URL is
then included in the local Discord activity payload. No credentials are stored
by the program; keep the launchd environment file mode `600`.

Discord activity is visible according to your Discord activity-privacy
settings. Stop the companion or disable activity sharing when you do not want
the current track shown.

## License

MIT. See [LICENSE](LICENSE).
