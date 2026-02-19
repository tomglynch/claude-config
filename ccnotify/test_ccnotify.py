#!/usr/bin/env python3
"""Tests for ccnotify notification logic."""

import os
import sqlite3
import tempfile
import unittest
from unittest.mock import MagicMock, patch, call

# Patch SCRIPT_DIR before importing so it uses a temp dir
_tmpdir = tempfile.mkdtemp()
with patch.dict(os.environ, {"ITERM_SESSION_ID": "w1t0p0:TEST-UUID-1234"}):
    import ccnotify
    ccnotify.SCRIPT_DIR = _tmpdir


def _make_tracker():
    """Create a tracker with an in-memory-like temp db, skip logging."""
    with patch.object(ccnotify.ClaudePromptTracker, "_setup_logging"):
        tracker = ccnotify.ClaudePromptTracker()
        tracker.db_path = os.path.join(_tmpdir, "test.db")
        tracker._init_database()
    return tracker


class TestParseItermSessionId(unittest.TestCase):
    def test_standard_format(self):
        with patch.dict(os.environ, {"ITERM_SESSION_ID": "w0t0p0:ABC-123"}):
            raw, uuid = ccnotify._parse_iterm_session_id()
            self.assertEqual(raw, "w0t0p0:ABC-123")
            self.assertEqual(uuid, "ABC-123")

    def test_no_colon(self):
        with patch.dict(os.environ, {"ITERM_SESSION_ID": "JUST-UUID"}):
            raw, uuid = ccnotify._parse_iterm_session_id()
            self.assertEqual(raw, "JUST-UUID")
            self.assertEqual(uuid, "JUST-UUID")

    def test_empty(self):
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("ITERM_SESSION_ID", None)
            raw, uuid = ccnotify._parse_iterm_session_id()
            self.assertEqual(raw, "")
            self.assertEqual(uuid, "")


class TestIsSessionFocused(unittest.TestCase):
    def _make_result(self, stdout="", stderr=""):
        result = MagicMock()
        result.stdout = stdout
        result.stderr = stderr
        return result

    @patch.dict(os.environ, {"ITERM_SESSION_ID": "w1t0p0:MY-UUID"})
    @patch("ccnotify.subprocess.run")
    def test_matching_uuid_returns_true(self, mock_run):
        mock_run.return_value = self._make_result(stdout="MY-UUID\n")
        tracker = _make_tracker()
        self.assertTrue(tracker._is_session_focused())

    @patch.dict(os.environ, {"ITERM_SESSION_ID": "w1t0p0:MY-UUID"})
    @patch("ccnotify.subprocess.run")
    def test_different_uuid_returns_false(self, mock_run):
        mock_run.return_value = self._make_result(stdout="OTHER-UUID\n")
        tracker = _make_tracker()
        self.assertFalse(tracker._is_session_focused())

    @patch.dict(os.environ, {"ITERM_SESSION_ID": "w1t0p0:MY-UUID"})
    @patch("ccnotify.subprocess.run")
    def test_not_iterm_frontmost_returns_false(self, mock_run):
        mock_run.return_value = self._make_result(stdout="NOTFRONT:Safari\n")
        tracker = _make_tracker()
        self.assertFalse(tracker._is_session_focused())

    @patch.dict(os.environ, {"ITERM_SESSION_ID": "w1t0p0:MY-UUID"})
    @patch("ccnotify.subprocess.run")
    def test_applescript_error_returns_false(self, mock_run):
        mock_run.return_value = self._make_result(stdout="ERROR:some error\n")
        tracker = _make_tracker()
        self.assertFalse(tracker._is_session_focused())

    @patch.dict(os.environ, {}, clear=False)
    def test_no_session_id_returns_false(self):
        os.environ.pop("ITERM_SESSION_ID", None)
        tracker = _make_tracker()
        self.assertFalse(tracker._is_session_focused())


class TestSendNotification(unittest.TestCase):
    """Test the 3 scenarios: focused, non-iTerm2 focused, different iTerm2 window."""

    @patch.dict(os.environ, {"ITERM_SESSION_ID": "w1t0p0:MY-UUID"})
    @patch("ccnotify.time.sleep")
    @patch("builtins.open", MagicMock())
    @patch("ccnotify.subprocess.Popen")
    @patch("ccnotify.subprocess.run")
    def test_focused_plays_glass_no_notification(self, mock_run, mock_popen, mock_sleep):
        """Test 1: Session focused → Glass sound + flash, no terminal-notifier."""
        # AppleScript returns matching UUID
        mock_run.return_value = MagicMock(stdout="MY-UUID\n", stderr="")
        tracker = _make_tracker()

        tracker.send_notification(title="test", subtitle="done")

        # afplay Glass should be called
        mock_popen.assert_called_once()
        afplay_args = mock_popen.call_args[0][0]
        self.assertEqual(afplay_args[0], "afplay")
        self.assertIn("Glass", afplay_args[1])

        # terminal-notifier should NOT be called (only osascript for focus check)
        notifier_calls = [c for c in mock_run.call_args_list
                         if "terminal-notifier" in str(c)]
        self.assertEqual(len(notifier_calls), 0)

        # Should sleep 0.7s before flash
        mock_sleep.assert_any_call(0.7)

    @patch.dict(os.environ, {"ITERM_SESSION_ID": "w1t0p0:MY-UUID"})
    @patch("ccnotify.time.sleep")
    @patch("builtins.open", MagicMock())
    @patch("ccnotify.subprocess.Popen")
    @patch("ccnotify.subprocess.run")
    def test_not_focused_sends_notification(self, mock_run, mock_popen, mock_sleep):
        """Test 2/3: Not focused → terminal-notifier + flash, no Glass."""
        # AppleScript returns different app (not iTerm2)
        focus_result = MagicMock(stdout="NOTFRONT:Safari\n", stderr="")
        notifier_result = MagicMock()
        mock_run.side_effect = [focus_result, notifier_result]

        tracker = _make_tracker()
        tracker.send_notification(title="test", subtitle="done")

        # terminal-notifier should be called
        notifier_calls = [c for c in mock_run.call_args_list
                         if c != mock_run.call_args_list[0]]  # skip osascript call
        self.assertEqual(len(notifier_calls), 1)
        cmd = notifier_calls[0][0][0]
        self.assertEqual(cmd[0], "terminal-notifier")
        self.assertIn("-group", cmd)

        # afplay should NOT be called
        mock_popen.assert_not_called()

    @patch.dict(os.environ, {"ITERM_SESSION_ID": "w1t0p0:MY-UUID"})
    @patch("ccnotify.time.sleep")
    @patch("builtins.open", MagicMock())
    @patch("ccnotify.subprocess.Popen")
    @patch("ccnotify.subprocess.run")
    def test_different_iterm_window_sends_notification(self, mock_run, mock_popen, mock_sleep):
        """Test 3: Different iTerm2 session focused → notification sent."""
        # AppleScript returns a different UUID (iTerm2 is front but different session)
        focus_result = MagicMock(stdout="OTHER-UUID\n", stderr="")
        notifier_result = MagicMock()
        mock_run.side_effect = [focus_result, notifier_result]

        tracker = _make_tracker()
        tracker.send_notification(title="test", subtitle="done")

        # terminal-notifier should be called
        all_run_calls = mock_run.call_args_list
        self.assertEqual(len(all_run_calls), 2)  # osascript + terminal-notifier

        # afplay should NOT be called
        mock_popen.assert_not_called()

    @patch.dict(os.environ, {"ITERM_SESSION_ID": "w1t0p0:MY-UUID"})
    @patch("ccnotify.time.sleep")
    @patch("builtins.open", MagicMock())
    @patch("ccnotify.subprocess.Popen")
    @patch("ccnotify.subprocess.run")
    def test_notification_uses_group_for_replacement(self, mock_run, mock_popen, mock_sleep):
        """Notifications use -group flag so they replace stale ones."""
        focus_result = MagicMock(stdout="NOTFRONT:Safari\n", stderr="")
        notifier_result = MagicMock()
        mock_run.side_effect = [focus_result, notifier_result]

        tracker = _make_tracker()
        tracker.send_notification(title="test", subtitle="done")

        cmd = mock_run.call_args_list[1][0][0]
        group_idx = cmd.index("-group")
        self.assertEqual(cmd[group_idx + 1], "w1t0p0:MY-UUID")

    @patch.dict(os.environ, {"ITERM_SESSION_ID": "w1t0p0:MY-UUID"})
    @patch("ccnotify.time.sleep")
    @patch("builtins.open", MagicMock())
    @patch("ccnotify.subprocess.Popen")
    @patch("ccnotify.subprocess.run")
    def test_notification_includes_execute_with_activate_script(self, mock_run, mock_popen, mock_sleep):
        """Click handler uses activate-session.sh with session UUID."""
        focus_result = MagicMock(stdout="NOTFRONT:Safari\n", stderr="")
        notifier_result = MagicMock()
        mock_run.side_effect = [focus_result, notifier_result]

        tracker = _make_tracker()
        tracker.send_notification(title="test", subtitle="done")

        cmd = mock_run.call_args_list[1][0][0]
        exec_idx = cmd.index("-execute")
        self.assertIn("activate-session.sh", cmd[exec_idx + 1])
        self.assertIn("MY-UUID", cmd[exec_idx + 1])


class TestPromptSubmitDismissesNotification(unittest.TestCase):
    @patch.dict(os.environ, {"ITERM_SESSION_ID": "w1t0p0:MY-UUID"})
    @patch("ccnotify.subprocess.run")
    def test_prompt_submit_removes_notification(self, mock_run):
        """Submitting a prompt dismisses any pending notification for the session."""
        mock_run.return_value = MagicMock()
        tracker = _make_tracker()
        data = {
            "session_id": "test-session",
            "prompt": "hello",
            "cwd": "/tmp",
            "hook_event_name": "UserPromptSubmit",
        }
        tracker.handle_user_prompt_submit(data)

        mock_run.assert_called_once()
        cmd = mock_run.call_args[0][0]
        self.assertEqual(cmd, ["terminal-notifier", "-remove", "w1t0p0:MY-UUID"])


class TestFormatDuration(unittest.TestCase):
    def test_seconds(self):
        self.assertEqual(
            ccnotify.ClaudePromptTracker._format_duration("2026-01-01 00:00:00", "2026-01-01 00:00:45"),
            "45s"
        )

    def test_minutes_and_seconds(self):
        self.assertEqual(
            ccnotify.ClaudePromptTracker._format_duration("2026-01-01 00:00:00", "2026-01-01 00:02:30"),
            "2m30s"
        )

    def test_exact_minutes(self):
        self.assertEqual(
            ccnotify.ClaudePromptTracker._format_duration("2026-01-01 00:00:00", "2026-01-01 00:03:00"),
            "3m"
        )

    def test_hours_and_minutes(self):
        self.assertEqual(
            ccnotify.ClaudePromptTracker._format_duration("2026-01-01 00:00:00", "2026-01-01 01:15:00"),
            "1h15m"
        )

    def test_exact_hours(self):
        self.assertEqual(
            ccnotify.ClaudePromptTracker._format_duration("2026-01-01 00:00:00", "2026-01-01 02:00:00"),
            "2h"
        )


class TestValidateInputData(unittest.TestCase):
    def test_valid_stop_event(self):
        data = {"session_id": "abc", "hook_event_name": "Stop"}
        ccnotify.validate_input_data(data, "Stop")  # should not raise

    def test_missing_field_raises(self):
        data = {"hook_event_name": "Stop"}  # missing session_id
        with self.assertRaises(ValueError):
            ccnotify.validate_input_data(data, "Stop")

    def test_event_mismatch_raises(self):
        data = {"session_id": "abc", "hook_event_name": "Stop"}
        with self.assertRaises(ValueError):
            ccnotify.validate_input_data(data, "Notification")

    def test_unknown_event_raises(self):
        with self.assertRaises(ValueError):
            ccnotify.validate_input_data({}, "FakeEvent")


if __name__ == "__main__":
    unittest.main()
