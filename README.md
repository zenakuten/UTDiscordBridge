# UTDiscordBridge

UTDiscordBridge forwards chat and server events from a UT2004 dedicated server
to a Discord channel.

It supports:

- public player chat;
- optional team chat;
- player and spectator joins/leaves;
- map changes;
- game results;
- conversion of configured UT2004 emoticons to Unicode emoji.

Discord requires HTTPS, which UT2004 cannot provide directly. The included
Python relay receives local HTTP messages from UT2004 and forwards them securely
to Discord.

## Requirements

- A UT2004 dedicated server
- Python 3.10 or newer
- A Discord webhook

No Python packages are required.

## Install the UT2004 package

Copy these files from the ZIP into the server's `System` directory:

```text
UTDiscordBridge.u
LibHTTP4.u
UTDiscordBridge.ini
```

Add the server actor to the server's active configuration file:

```ini
[Engine.GameEngine]
ServerActors=UTDiscordBridge.UTDiscordBridgeServerActor
```

If `[Engine.GameEngine]` already exists, add only the `ServerActors=` line to
that section.

## Configure the bridge

Edit `System/UTDiscordBridge.ini`:

```ini
[UTDiscordBridge.UTDiscordBridgeServerActor]
bEnabled=True
WebhookURL=https://discord.com/api/webhooks/WEBHOOK_ID/WEBHOOK_TOKEN
RelayURL=http://127.0.0.1:8766/v1/events
RelayToken=
ServerLabel=UT2004 Server
bForwardChat=True
bForwardTeamChat=False
bForwardGameEvents=True
bForwardPlayerEvents=True
bIgnoreBotEvents=True
QueueLimit=100
MaxRetries=5
RequestTimeout=5.000000
bDebug=False
```

`ServerLabel` is the public server name shown in Discord. The bridge never uses
the machine hostname.

Team chat is disabled by default because forwarding it to a public Discord
channel may reveal private team communication.

Bot and WebAdmin chat, join, and leave events are ignored by default. Set
`bIgnoreBotEvents=False` to forward them.

Treat `WebhookURL` as a password. Do not post it publicly or include it in logs.
Regenerate the webhook in Discord if it is exposed.

## Run the relay

Copy the `relay` folder to the same machine as the UT2004 server, then run:

```bash
cd relay
python3 utdiscord_relay.py
```

The relay listens only on `127.0.0.1:8766` by default. Leave it running while
the game server is online.

If `Emoticons.ini` is beside the relay script, supported game emoticons are
converted automatically:

```text
:)                  -> 🙂
:D                  -> 😃
=holdingbacktears   -> 🥹
```

Custom image-only emoticons without a Unicode equivalent remain as text.

## Start the relay automatically on Linux

An example systemd unit is included in `relay/utdiscord-relay.service`. Adjust
its user and paths for your server, copy it into `/etc/systemd/system`, then
enable it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now utdiscord-relay.service
```

View relay logs with:

```bash
journalctl -u utdiscord-relay.service -f
```

## Restart and verify

Restart the relay and UT2004 server after installing or updating the bridge.
The relay should report:

```text
listening on 127.0.0.1:8766
```

When emoticons are loaded, it also reports the number of Unicode mappings.
Loading a map should produce a "Switching map" embed in Discord. Starting and
ending the match should produce separate lifecycle messages.

UT2004 log messages from the bridge use the `UTDB` prefix.

## Troubleshooting

**No Discord messages**

- Confirm the relay is running.
- Confirm `RelayURL` uses `http://127.0.0.1:8766/v1/events`.
- Confirm the Discord webhook is valid and begins with
  `https://discord.com/api/webhooks/`.
- Check the relay output and search the UT2004 server log for `UTDB`.

**Relay reports connection refused**

Start the relay before starting UT2004, or wait for the bridge's automatic
retry.

**Emoticons remain as text**

Place the server's `Emoticons.ini` beside `utdiscord_relay.py`, then restart the
relay.

**Duplicate or missing team messages**

Check `bForwardTeamChat`. It is intentionally disabled by default.
