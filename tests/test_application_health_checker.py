import socket
import unittest
import urllib.error
from unittest.mock import patch

from scripts.application_health_checker import check_url


class ApplicationHealthCheckerTests(unittest.TestCase):
    @patch("scripts.application_health_checker.urllib.request.urlopen")
    def test_successful_response_is_up(self, urlopen):
        response = urlopen.return_value.__enter__.return_value
        response.status = 204

        is_up, status, elapsed, error = check_url("https://example.test", 2)

        self.assertTrue(is_up)
        self.assertEqual(status, 204)
        self.assertGreaterEqual(elapsed, 0)
        self.assertIsNone(error)

    @patch("scripts.application_health_checker.urllib.request.urlopen")
    def test_http_error_is_down_with_status(self, urlopen):
        urlopen.side_effect = urllib.error.HTTPError(
            "https://example.test", 503, "Unavailable", {}, None
        )

        is_up, status, _, error = check_url("https://example.test", 2)

        self.assertFalse(is_up)
        self.assertEqual(status, 503)
        self.assertEqual(error, "HTTP status 503")

    @patch("scripts.application_health_checker.urllib.request.urlopen")
    def test_connection_error_is_down(self, urlopen):
        urlopen.side_effect = urllib.error.URLError("connection refused")

        is_up, status, _, error = check_url("http://example.test", 2)

        self.assertFalse(is_up)
        self.assertIsNone(status)
        self.assertIn("connection refused", error)

    @patch("scripts.application_health_checker.urllib.request.urlopen")
    def test_timeout_is_down(self, urlopen):
        urlopen.side_effect = socket.timeout("timed out")

        is_up, status, _, error = check_url("http://example.test", 0.01)

        self.assertFalse(is_up)
        self.assertIsNone(status)
        self.assertIn("timed out", error)

    @patch("scripts.application_health_checker.urllib.request.urlopen")
    def test_invalid_url_does_not_make_request(self, urlopen):
        is_up, status, elapsed, error = check_url("file:///etc/passwd", 2)

        self.assertFalse(is_up)
        self.assertIsNone(status)
        self.assertEqual(elapsed, 0)
        self.assertIn("Invalid URL", error)
        urlopen.assert_not_called()

    @patch("scripts.application_health_checker.urllib.request.urlopen")
    def test_embedded_credentials_are_not_allowed(self, urlopen):
        result = check_url("https://user:secret@example.test", 2)

        self.assertFalse(result[0])
        self.assertIn("embedded credentials", result[3])
        urlopen.assert_not_called()


if __name__ == "__main__":
    unittest.main()
