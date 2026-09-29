#!/usr/bin/env python3

import argparse
import hmac
import json
import logging
import os
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY_BYTES = 64 * 1024
MAX_DISCORD_CONTENT = 2000
ALLOWED_EVENT_TYPES = {
    "chat",
    "map_start",
    "game_end",
    "player_join",
    "player_leave",
    "player_mode",
}
ALLOWED_WEBHOOK_HOSTS = {
    "discord.com",
    "canary.discord.com",
    "ptb.discord.com",
    "discordapp.com",
    "canary.discordapp.com",
    "ptb.discordapp.com",
}

LOG = logging.getLogger("utdiscord-relay")
EMOTICON_LINE = re.compile(
    r'^Smileys=\(Event="([^"]+)",Icon=Texture\'WsEmoticons\.([^\']+)\'\)$'
)
CODEPOINT_SEQUENCE = re.compile(r"^[0-9a-fA-F]{4,6}(?:-[0-9a-fA-F]{4,6})*$")


class RelayError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(
            req.full_url, code, "Discord redirect rejected", headers, fp
        )


def validate_webhook_url(value):
    if not isinstance(value, str):
        raise RelayError(400, "webhook_url must be a string")

    parsed = urllib.parse.urlsplit(value)
    try:
        port = parsed.port
    except ValueError as error:
        raise RelayError(400, "invalid Discord webhook URL") from error

    if (
        parsed.scheme != "https"
        or parsed.hostname not in ALLOWED_WEBHOOK_HOSTS
        or port not in (None, 443)
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise RelayError(400, "invalid Discord webhook URL")

    parts = parsed.path.split("/")
    if (
        len(parts) != 5
        or parts[1:3] != ["api", "webhooks"]
        or not parts[3].isdigit()
        or not parts[4]
    ):
        raise RelayError(400, "invalid Discord webhook path")

    return value


def require_text(event, key):
    value = event.get(key)
    if not isinstance(value, str):
        raise RelayError(400, f"{key} must be a string")
    return value


def escape_markdown_name(value):
    value = value.replace("\\", "\\\\")
    for char in ("*", "_", "~", "`", "|"):
        value = value.replace(char, "\\" + char)
    return value.replace("\r", " ").replace("\n", " ")[:80]


def clean_text(value, limit):
    return value.replace("\x00", "").replace("\r\n", "\n").replace("\r", "\n")[:limit]


def load_emoticons(path):
    mappings = []
    seen = set()

    with Path(path).open("r", encoding="latin-1") as source:
        for raw_line in source:
            match = EMOTICON_LINE.match(raw_line.strip())
            if match is None:
                continue

            alias, texture_name = match.groups()
            if not alias or alias in seen:
                continue
            if CODEPOINT_SEQUENCE.fullmatch(texture_name) is None:
                continue

            try:
                emoji = "".join(chr(int(value, 16)) for value in texture_name.split("-"))
            except (ValueError, OverflowError):
                continue

            mappings.append((alias, emoji))
            seen.add(alias)

    return mappings


def replace_emoticons(message, mappings):
    if not mappings:
        return message

    output = []
    cursor = 0
    while cursor < len(message):
        match_at = -1
        match_alias = ""
        match_emoji = ""

        for alias, emoji in mappings:
            index = message.find(alias, cursor)
            if index != -1 and (match_at == -1 or index < match_at):
                match_at = index
                match_alias = alias
                match_emoji = emoji

        if match_at == -1:
            output.append(message[cursor:])
            break

        output.append(message[cursor:match_at])
        output.append(match_emoji)
        cursor = match_at + len(match_alias)

    return "".join(output)


def format_discord_payload(event, emoticons=()):
    if not isinstance(event, dict):
        raise RelayError(400, "request body must be a JSON object")
    if event.get("version") != 1:
        raise RelayError(400, "unsupported event version")

    event_type = event.get("type")
    if event_type not in ALLOWED_EVENT_TYPES:
        raise RelayError(400, "unsupported event type")

    server = escape_markdown_name(require_text(event, "server"))
    map_name = escape_markdown_name(require_text(event, "map"))

    if event_type == "chat":
        player = escape_markdown_name(require_text(event, "player"))
        message = clean_text(require_text(event, "message"), 1700)
        message = replace_emoticons(message, emoticons)
        prefix = "[TEAM] " if event.get("team") is True else ""
        content = f"{prefix}**{player}:** {message}"
    elif event_type == "map_start":
        content = f"**{server}** started **{map_name}**."
    elif event_type in {"player_join", "player_leave"}:
        player = escape_markdown_name(require_text(event, "player"))
        subject = "Spectator" if event.get("spectator") is True else "Player"
        action = "joined" if event_type == "player_join" else "left"
        content = f"{subject} **{player}** {action} **{server}**."
    elif event_type == "player_mode":
        player = escape_markdown_name(require_text(event, "player"))
        if event.get("spectator") is True:
            content = f"Player **{player}** became a spectator on **{server}**."
        else:
            content = f"Spectator **{player}** joined the game on **{server}**."
    else:
        reason = escape_markdown_name(require_text(event, "reason"))
        winner = event.get("winner")
        if winner is None:
            content = f"**{server}** finished **{map_name}** ({reason})."
        else:
            winner = escape_markdown_name(require_text(event, "winner"))
            score = event.get("score")
            if not isinstance(score, int):
                raise RelayError(400, "score must be an integer")
            content = (
                f"**{server}** finished **{map_name}**. "
                f"Winner: **{winner}** ({score}) - {reason}."
            )

    return {
        "content": content[:MAX_DISCORD_CONTENT],
        "allowed_mentions": {"parse": []},
    }


def parse_retry_after(body, headers):
    try:
        value = json.loads(body.decode("utf-8")).get("retry_after")
        if isinstance(value, (int, float)):
            return max(0.0, min(float(value), 30.0))
    except (UnicodeDecodeError, json.JSONDecodeError, AttributeError):
        pass

    value = headers.get("Retry-After")
    try:
        return max(0.0, min(float(value), 30.0))
    except (TypeError, ValueError):
        return 1.0


def send_to_discord(webhook_url, payload, opener, max_rate_limit_retries=2):
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    for attempt in range(max_rate_limit_retries + 1):
        request = urllib.request.Request(
            webhook_url,
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "User-Agent": "UTDiscordBridge/1.0",
            },
        )
        try:
            with opener.open(request, timeout=10) as response:
                if 200 <= response.status < 300:
                    return response.status
                raise RelayError(502, f"Discord returned status {response.status}")
        except urllib.error.HTTPError as error:
            response_body = error.read(MAX_BODY_BYTES)
            if error.code == 429 and attempt < max_rate_limit_retries:
                time.sleep(parse_retry_after(response_body, error.headers))
                continue
            if error.code == 429:
                raise RelayError(429, "Discord rate limit retry exhausted") from error
            if 400 <= error.code < 500:
                raise RelayError(400, f"Discord rejected the webhook with status {error.code}") from error
            raise RelayError(502, f"Discord returned status {error.code}") from error
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise RelayError(502, "could not connect to Discord") from error

    raise RelayError(502, "Discord request failed")


class RelayServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, handler, token, opener, emoticons=()):
        super().__init__(address, handler)
        self.relay_token = token
        self.discord_opener = opener
        self.emoticons = emoticons


class RelayHandler(BaseHTTPRequestHandler):
    server_version = "UTDiscordRelay/1.0"
    sys_version = ""

    def do_POST(self):
        try:
            self.handle_event()
        except RelayError as error:
            LOG.warning("request rejected: %s", error.message)
            self.send_json(error.status, {"error": error.message})
        except Exception:
            LOG.exception("unexpected relay failure")
            self.send_json(500, {"error": "internal relay error"})

    def handle_event(self):
        if self.path != "/v1/events":
            raise RelayError(404, "not found")

        expected = self.server.relay_token
        supplied = self.headers.get("X-UTDB-Token", "")
        if expected and not hmac.compare_digest(expected, supplied):
            raise RelayError(401, "invalid relay token")

        content_type = self.headers.get_content_type()
        if content_type != "application/json":
            raise RelayError(415, "content type must be application/json")

        try:
            content_length = int(self.headers.get("Content-Length", ""))
        except ValueError as error:
            raise RelayError(411, "valid content length required") from error
        if content_length < 1 or content_length > MAX_BODY_BYTES:
            raise RelayError(413, "request body size is invalid")

        raw_body = self.rfile.read(content_length)
        try:
            event = json.loads(raw_body.decode("latin-1"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise RelayError(400, "invalid JSON") from error

        webhook_url = validate_webhook_url(event.get("webhook_url"))
        payload = format_discord_payload(event, self.server.emoticons)
        status = send_to_discord(
            webhook_url, payload, self.server.discord_opener
        )
        LOG.info("forwarded %s event", event["type"])
        # Always reply 200 with a small body and close the connection.
        # LibHTTP in UT2004 does not reliably finish a request whose reply
        # is an empty 204, which leaves the bridge's queue waiting forever.
        self.close_connection = True
        self.send_json(200, {"ok": True})

    def send_json(self, status, value):
        body = json.dumps(value, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, message_format, *args):
        LOG.info("%s - %s", self.client_address[0], message_format % args)


def build_opener():
    context = ssl.create_default_context()
    https_handler = urllib.request.HTTPSHandler(context=context)
    return urllib.request.build_opener(NoRedirectHandler(), https_handler)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Forward UTDiscordBridge events to Discord over HTTPS."
    )
    parser.add_argument(
        "--host",
        default=os.environ.get("UTDB_RELAY_HOST", "127.0.0.1"),
        help="listen address (default: 127.0.0.1)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("UTDB_RELAY_PORT", "8766")),
        help="listen port (default: 8766)",
    )
    parser.add_argument(
        "--token",
        default=os.environ.get("UTDB_RELAY_TOKEN", ""),
        help="shared relay token (prefer UTDB_RELAY_TOKEN)",
    )
    parser.add_argument(
        "--emoticons",
        default=os.environ.get("UTDB_EMOTICONS_FILE", ""),
        help="path to the server's Emoticons.ini",
    )
    parser.add_argument("--debug", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    if args.host not in {"127.0.0.1", "::1", "localhost"}:
        LOG.warning("relay is listening on a non-loopback address")
    if not args.token:
        LOG.warning("no relay token configured; loopback-only use is required")

    emoticons_path = args.emoticons
    if not emoticons_path:
        script_dir = Path(__file__).resolve().parent
        for candidate in (
            script_dir / "Emoticons.ini",
            script_dir / "emoticons" / "Emoticons.ini",
            script_dir.parent / "emoticons" / "Emoticons.ini",
        ):
            if candidate.is_file():
                emoticons_path = str(candidate)
                break

    emoticons = ()
    if emoticons_path:
        try:
            emoticons = load_emoticons(emoticons_path)
        except OSError as error:
            raise SystemExit(f"could not load emoticons file: {error}") from error
        LOG.info("loaded %d Unicode emoticon mappings", len(emoticons))
    else:
        LOG.info("no Emoticons.ini found; game emoticons will remain literal")

    server = RelayServer(
        (args.host, args.port), RelayHandler, args.token, build_opener(), emoticons
    )
    LOG.info("listening on %s:%d", args.host, args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
