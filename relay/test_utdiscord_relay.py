import io
import http.client
import json
import threading
import unittest
import urllib.error
from pathlib import Path

import utdiscord_relay as relay


class FakeResponse:
    def __init__(self, status=204):
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False


class FakeOpener:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append((request, timeout))
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


def event(event_type="chat"):
    value = {
        "version": 1,
        "type": event_type,
        "webhook_url": "https://discord.com/api/webhooks/123/token",
        "server": "Test Server",
        "map": "DM-Rankin",
        "game_type": "XGame.xDeathMatch",
    }
    if event_type == "chat":
        value.update(player="Player", team=False, message="hello")
    elif event_type == "game_end":
        value.update(reason="fraglimit", winner="Player", score=25)
    elif event_type in {"player_join", "player_leave"}:
        value.update(player="Player", spectator=False)
    return value


class ValidationTests(unittest.TestCase):
    def test_accepts_discord_webhook(self):
        value = "https://discord.com/api/webhooks/123/token"
        self.assertEqual(relay.validate_webhook_url(value), value)

    def test_rejects_http_and_arbitrary_hosts(self):
        for value in (
            "http://discord.com/api/webhooks/123/token",
            "https://example.com/api/webhooks/123/token",
            "https://discord.com.example.com/api/webhooks/123/token",
            "https://discord.com/api/webhooks/123/token?wait=true",
        ):
            with self.subTest(value=value):
                with self.assertRaises(relay.RelayError):
                    relay.validate_webhook_url(value)

    def test_chat_payload_disables_mentions(self):
        value = event()
        value["player"] = "A*lice"
        value["message"] = "@everyone hello"
        payload = relay.format_discord_payload(value)
        self.assertEqual(payload["allowed_mentions"], {"parse": []})
        self.assertEqual(payload["content"], "**A\\*lice:** @everyone hello")

    def test_team_chat_is_labeled(self):
        value = event()
        value["team"] = True
        payload = relay.format_discord_payload(value)
        self.assertTrue(payload["content"].startswith("[TEAM] "))

    def test_formats_lifecycle_events(self):
        self.assertIn("started", relay.format_discord_payload(event("map_start"))["content"])
        self.assertIn("Winner", relay.format_discord_payload(event("game_end"))["content"])
        self.assertEqual(
            relay.format_discord_payload(event("player_join"))["content"],
            "Player **Player** joined **Test Server**.",
        )
        self.assertEqual(
            relay.format_discord_payload(event("player_leave"))["content"],
            "Player **Player** left **Test Server**.",
        )

    def test_loads_and_replaces_server_emoticons(self):
        path = Path(__file__).parent.parent / "emoticons" / "Emoticons.ini"
        mappings = relay.load_emoticons(path)
        lookup = dict(mappings)
        self.assertGreater(len(mappings), 200)
        self.assertEqual(lookup["=holdingbacktears"], "\U0001f979")
        self.assertEqual(lookup["=tired"], "\U0001f62b")
        self.assertEqual(lookup[":)"], "\U0001f642")
        self.assertEqual(lookup[":D"], "\U0001f603")
        self.assertNotIn("=snarf", lookup)
        self.assertEqual(
            relay.replace_emoticons(
                "gg :) :D =holdingbacktears =thumbup =snarf", mappings
            ),
            "gg \U0001f642 \U0001f603 \U0001f979 \U0001f44d =snarf",
        )

    def test_chat_payload_replaces_emoticons(self):
        value = event()
        value["message"] = "hello =holdingbacktears"
        payload = relay.format_discord_payload(
            value, [("=holdingbacktears", "\U0001f979")]
        )
        self.assertEqual(payload["content"], "**Player:** hello \U0001f979")


class DiscordRequestTests(unittest.TestCase):
    def test_sends_expected_json(self):
        opener = FakeOpener([FakeResponse()])
        status = relay.send_to_discord(
            event()["webhook_url"],
            {"content": "hello", "allowed_mentions": {"parse": []}},
            opener,
        )
        self.assertEqual(status, 204)
        request, timeout = opener.requests[0]
        self.assertEqual(timeout, 10)
        body = json.loads(request.data.decode("utf-8"))
        self.assertEqual(body["content"], "hello")
        self.assertEqual(body["allowed_mentions"], {"parse": []})

    def test_retries_discord_rate_limit(self):
        error = urllib.error.HTTPError(
            "https://discord.com/api/webhooks/123/token",
            429,
            "rate limited",
            {"Retry-After": "0"},
            io.BytesIO(b'{"retry_after":0}'),
        )
        opener = FakeOpener([error, FakeResponse()])
        status = relay.send_to_discord(
            event()["webhook_url"], {"content": "hello"}, opener
        )
        self.assertEqual(status, 204)
        self.assertEqual(len(opener.requests), 2)

    def test_does_not_follow_redirect(self):
        handler = relay.NoRedirectHandler()
        with self.assertRaises(urllib.error.HTTPError) as caught:
            handler.redirect_request(
                type("Request", (), {"full_url": "https://discord.com"})(),
                None,
                302,
                "redirect",
                {},
                "https://example.com",
            )
        caught.exception.close()


class RelayIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.opener = FakeOpener([FakeResponse()])
        self.server = relay.RelayServer(
            ("127.0.0.1", 0), relay.RelayHandler, "secret", self.opener
        )
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def post(self, body, token="secret"):
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_address[1], timeout=2
        )
        connection.request(
            "POST",
            "/v1/events",
            body=json.dumps(body).encode("latin-1"),
            headers={
                "Content-Type": "application/json",
                "X-UTDB-Token": token,
            },
        )
        response = connection.getresponse()
        response_body = response.read()
        connection.close()
        return response.status, response_body

    def test_forwards_event_end_to_end(self):
        status, body = self.post(event())
        self.assertEqual(status, 204)
        self.assertEqual(body, b"")
        request, timeout = self.opener.requests[0]
        payload = json.loads(request.data.decode("utf-8"))
        self.assertEqual(payload["content"], "**Player:** hello")
        self.assertEqual(payload["allowed_mentions"], {"parse": []})
        self.assertEqual(timeout, 10)

    def test_rejects_bad_token_without_forwarding(self):
        status, body = self.post(event(), token="wrong")
        self.assertEqual(status, 401)
        self.assertIn(b"invalid relay token", body)
        self.assertEqual(self.opener.requests, [])


if __name__ == "__main__":
    unittest.main()
