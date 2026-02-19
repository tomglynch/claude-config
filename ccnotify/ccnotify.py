#!/usr/bin/env python3
"""
Claude Code Notify
https://github.com/dazuiba/CCNotify
"""

import json
import logging
import os
import sqlite3
import subprocess
import sys
import time
from datetime import datetime
from logging.handlers import TimedRotatingFileHandler

FLASH_COLOR = "4a3a00"
BG_COLOR = "2d2d3d"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def _parse_iterm_session_id():
    """Extract the session UUID from ITERM_SESSION_ID (format: 'w0t0p0:UUID')."""
    raw = os.environ.get("ITERM_SESSION_ID", "")
    if not raw:
        return "", ""
    uuid = raw.split(":")[-1] if ":" in raw else raw
    return raw, uuid


class ClaudePromptTracker:
    def __init__(self):
        self.db_path = os.path.join(SCRIPT_DIR, "ccnotify.db")
        self._setup_logging()
        self._init_database()

    def _setup_logging(self):
        log_path = os.path.join(SCRIPT_DIR, "ccnotify.log")

        handler = TimedRotatingFileHandler(
            log_path,
            when="midnight",
            interval=1,
            backupCount=1,
            encoding="utf-8",
        )
        handler.setFormatter(logging.Formatter(
            "%(asctime)s - %(levelname)s - %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
        ))

        logger = logging.getLogger()
        logger.setLevel(logging.INFO)
        logger.addHandler(handler)

    def _init_database(self):
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS prompt (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
                    prompt TEXT,
                    cwd TEXT,
                    seq INTEGER,
                    stoped_at DATETIME,
                    lastWaitUserAt DATETIME
                )
            """)

            conn.execute("""
                CREATE TRIGGER IF NOT EXISTS auto_increment_seq
                AFTER INSERT ON prompt
                FOR EACH ROW
                BEGIN
                    UPDATE prompt
                    SET seq = (
                        SELECT COALESCE(MAX(seq), 0) + 1
                        FROM prompt
                        WHERE session_id = NEW.session_id
                    )
                    WHERE id = NEW.id;
                END
            """)

            conn.commit()

    def handle_user_prompt_submit(self, data):
        session_id = data.get("session_id")

        # User is back — dismiss any pending notification for this session
        _, session_uuid = _parse_iterm_session_id()
        if session_uuid:
            subprocess.run(
                ["terminal-notifier", "-remove", session_uuid],
                check=False, capture_output=True
            )

        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                "INSERT INTO prompt (session_id, prompt, cwd) VALUES (?, ?, ?)",
                (session_id, data.get("prompt", ""), data.get("cwd", "")),
            )
            conn.commit()

        logging.info(f"Recorded prompt for session {session_id}")

    def handle_stop(self, data):
        session_id = data.get("session_id")

        with sqlite3.connect(self.db_path) as conn:
            row = conn.execute(
                """SELECT id, created_at, cwd FROM prompt
                   WHERE session_id = ? AND stoped_at IS NULL
                   ORDER BY created_at DESC LIMIT 1""",
                (session_id,),
            ).fetchone()

            if not row:
                return

            record_id, created_at, cwd = row

            conn.execute(
                "UPDATE prompt SET stoped_at = CURRENT_TIMESTAMP WHERE id = ?",
                (record_id,),
            )
            conn.commit()

            seq_row = conn.execute(
                "SELECT seq FROM prompt WHERE id = ?", (record_id,)
            ).fetchone()
            seq = seq_row[0] if seq_row else 1

            duration = self._calculate_duration_from_db(record_id)
            self.send_notification(
                title=os.path.basename(cwd) if cwd else "Claude Task",
                subtitle=f"job#{seq} done, duration: {duration}",
                cwd=cwd,
            )

            logging.info(
                f"Task completed for session {session_id}, job#{seq}, duration: {duration}"
            )

    def handle_notification(self, data):
        session_id = data.get("session_id")
        message = data.get("message", "")
        cwd = data.get("cwd", "")

        logging.info(f"[NOTIFICATION] session={session_id}, message='{message}'")

        message_lower = message.lower()

        # "waiting for input" updates DB only; the Stop handler sends the notification
        is_waiting = ("waiting for your input" in message_lower
                      or "waiting for input" in message_lower)
        if is_waiting:
            with sqlite3.connect(self.db_path) as conn:
                conn.execute(
                    """UPDATE prompt SET lastWaitUserAt = CURRENT_TIMESTAMP
                       WHERE id = (
                           SELECT id FROM prompt WHERE session_id = ?
                           ORDER BY created_at DESC LIMIT 1
                       )""",
                    (session_id,),
                )
                conn.commit()
            logging.info(f"Updated lastWaitUserAt for session {session_id}")
            return

        if "permission" in message_lower:
            subtitle = "Permission Required"
        elif "approval" in message_lower or "choose an option" in message_lower:
            subtitle = "Action Required"
        else:
            subtitle = "Notification"

        self.send_notification(
            title=os.path.basename(cwd) if cwd else "Claude Task",
            subtitle=subtitle,
            cwd=cwd,
        )
        logging.info(f"Notification sent for session {session_id}: {subtitle}")

    def _calculate_duration_from_db(self, record_id):
        with sqlite3.connect(self.db_path) as conn:
            row = conn.execute(
                "SELECT created_at, stoped_at FROM prompt WHERE id = ?",
                (record_id,),
            ).fetchone()

            if row and row[1]:
                return self._format_duration(row[0], row[1])

        return "Unknown"

    @staticmethod
    def _format_duration(start_time, end_time):
        try:
            start_dt = datetime.fromisoformat(start_time.replace("Z", "+00:00"))
            end_dt = datetime.fromisoformat(end_time.replace("Z", "+00:00"))
            total_seconds = int((end_dt - start_dt).total_seconds())

            if total_seconds < 60:
                return f"{total_seconds}s"

            hours, remainder = divmod(total_seconds, 3600)
            minutes, seconds = divmod(remainder, 60)

            if hours > 0:
                return f"{hours}h{minutes}m" if minutes else f"{hours}h"
            return f"{minutes}m{seconds}s" if seconds else f"{minutes}m"
        except Exception as e:
            logging.error(f"Error calculating duration: {e}")
            return "Unknown"

    def _is_session_focused(self):
        """Check if this iTerm2 session is the active one in the frontmost window."""
        _, session_uuid = _parse_iterm_session_id()
        if not session_uuid:
            return False

        applescript = '''
            tell application "System Events"
                set frontApp to name of first application process whose frontmost is true
            end tell
            if frontApp is not "iTerm2" then return "NOTFRONT:" & frontApp
            tell application "iTerm2"
                try
                    return unique ID of current session of current tab of current window
                on error errMsg
                    return "ERROR:" & errMsg
                end try
            end tell
        '''
        try:
            result = subprocess.run(
                ["osascript", "-e", applescript],
                capture_output=True, text=True, timeout=2
            )
            raw = result.stdout.strip()
            if raw.startswith(("NOTFRONT:", "ERROR:")):
                return False
            return raw == session_uuid
        except Exception as e:
            logging.warning(f"Could not check session focus: {e}")
            return False

    def _flash_bg(self):
        """Single 0.2s amber flash of the terminal background."""
        try:
            with open("/dev/tty", "w") as tty:
                tty.write(f"\033]1337;SetColors=bg={FLASH_COLOR}\007")
                tty.flush()
                time.sleep(0.2)
                tty.write(f"\033]1337;SetColors=bg={BG_COLOR}\007")
                tty.flush()
        except Exception as e:
            logging.warning(f"Could not flash bg: {e}")

    def send_notification(self, title, subtitle, cwd=None):
        """Send macOS notification via terminal-notifier, or flash if session is focused."""
        if self._is_session_focused():
            subprocess.Popen(
                ["afplay", "/System/Library/Sounds/Glass.aiff"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            time.sleep(0.7)
            self._flash_bg()
            logging.info(f"Notification skipped (session focused): {title} - {subtitle}")
            return

        iterm_session, session_uuid = _parse_iterm_session_id()
        current_time = datetime.now().strftime("%B %d, %Y at %H:%M")

        try:
            cmd = [
                "terminal-notifier",
                "-sound", "default",
                "-title", title,
                "-subtitle", f"{subtitle}\n{current_time}",
                "-group", session_uuid or "claude-code",
            ]

            if session_uuid:
                activate_script = os.path.join(SCRIPT_DIR, "activate-session.sh")
                cmd.extend(["-execute", f'{activate_script} "{session_uuid}"'])
            else:
                cmd.extend(["-activate", "com.googlecode.iterm2"])

            subprocess.run(cmd, check=False, capture_output=True)
            self._flash_bg()
            logging.info(f"Notification sent: {title} - {subtitle} (session: {iterm_session})")
        except FileNotFoundError:
            logging.warning("terminal-notifier not found, notification skipped")
        except Exception as e:
            logging.error(f"Error sending notification: {e}")


REQUIRED_FIELDS = {
    "UserPromptSubmit": ["session_id", "prompt", "cwd", "hook_event_name"],
    "Stop": ["session_id", "hook_event_name"],
    "Notification": ["session_id", "message", "hook_event_name"],
}


def validate_input_data(data, expected_event_name):
    if expected_event_name not in REQUIRED_FIELDS:
        raise ValueError(f"Unknown event type: {expected_event_name}")

    if data.get("hook_event_name") != expected_event_name:
        raise ValueError(
            f"Event name mismatch: expected {expected_event_name}, "
            f"got {data.get('hook_event_name')}"
        )

    missing = [f for f in REQUIRED_FIELDS[expected_event_name]
                if f not in data or data[f] is None]
    if missing:
        raise ValueError(
            f"Missing required fields for {expected_event_name}: {missing}"
        )


EVENT_HANDLERS = {
    "UserPromptSubmit": ClaudePromptTracker.handle_user_prompt_submit,
    "Stop": ClaudePromptTracker.handle_stop,
    "Notification": ClaudePromptTracker.handle_notification,
}


def main():
    try:
        if len(sys.argv) < 2:
            print("ok")
            return

        event_name = sys.argv[1]
        if event_name not in EVENT_HANDLERS:
            logging.error(f"Invalid hook type: {event_name}")
            sys.exit(1)

        input_data = sys.stdin.read().strip()
        if not input_data:
            logging.warning("No input data received")
            return

        data = json.loads(input_data)
        validate_input_data(data, event_name)

        tracker = ClaudePromptTracker()
        EVENT_HANDLERS[event_name](tracker, data)

    except json.JSONDecodeError as e:
        logging.error(f"JSON decode error: {e}")
        sys.exit(1)
    except ValueError as e:
        logging.error(f"Validation error: {e}")
        sys.exit(1)
    except Exception as e:
        logging.error(f"Unexpected error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
