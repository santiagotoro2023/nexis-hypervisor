import sqlite3
import threading
from config import DB_FILE

_local = threading.local()


def conn() -> sqlite3.Connection:
    if not hasattr(_local, 'conn') or _local.conn is None:
        _local.conn = sqlite3.connect(str(DB_FILE), check_same_thread=False)
        _local.conn.row_factory = sqlite3.Row
        _local.conn.execute('PRAGMA journal_mode=WAL')
    return _local.conn


def init():
    c = conn()
    c.executescript("""
        CREATE TABLE IF NOT EXISTS sessions (
            token TEXT PRIMARY KEY,
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS nexis_pairing (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            controller_url TEXT NOT NULL,
            controller_token TEXT NOT NULL,
            controller_name TEXT,
            paired_at TEXT NOT NULL,
            last_ping TEXT,
            last_sync TEXT
        );

        CREATE TABLE IF NOT EXISTS audit_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            action TEXT NOT NULL,
            detail TEXT,
            source TEXT
        );
    """)
    c.commit()


def log_action(action: str, detail: str = '', source: str = 'web'):
    from datetime import datetime, timezone
    conn().execute(
        'INSERT INTO audit_log (ts, action, detail, source) VALUES (?, ?, ?, ?)',
        (datetime.now(timezone.utc).isoformat(), action, detail, source)
    )
    conn().commit()
