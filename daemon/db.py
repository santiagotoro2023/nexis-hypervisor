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
            token       TEXT PRIMARY KEY,
            username    TEXT NOT NULL DEFAULT 'creator',
            created_at  TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS local_users (
            username    TEXT PRIMARY KEY,
            hash        TEXT NOT NULL,
            role        TEXT NOT NULL DEFAULT 'user',
            created_at  TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS nexis_pairing (
            id               INTEGER PRIMARY KEY CHECK (id = 1),
            controller_url   TEXT NOT NULL,
            controller_token TEXT NOT NULL,
            controller_name  TEXT,
            sso_enabled      INTEGER NOT NULL DEFAULT 1,
            paired_at        TEXT NOT NULL,
            last_ping        TEXT,
            last_sync        TEXT
        );

        CREATE TABLE IF NOT EXISTS cluster_nodes (
            node_id    TEXT PRIMARY KEY,
            name       TEXT NOT NULL,
            url        TEXT NOT NULL,
            role       TEXT NOT NULL DEFAULT 'worker',
            joined_at  TEXT NOT NULL,
            last_seen  TEXT
        );

        CREATE TABLE IF NOT EXISTS audit_log (
            id     INTEGER PRIMARY KEY AUTOINCREMENT,
            ts     TEXT NOT NULL,
            action TEXT NOT NULL,
            detail TEXT,
            source TEXT
        );

        CREATE TABLE IF NOT EXISTS vm_metadata (
            vm_id       TEXT PRIMARY KEY,
            is_template INTEGER NOT NULL DEFAULT 0,
            notes       TEXT
        );
    """)
    # Seed default local user if absent
    import hashlib
    existing = c.execute('SELECT 1 FROM local_users WHERE username=?', ('creator',)).fetchone()
    if not existing:
        from datetime import datetime, timezone
        c.execute(
            'INSERT INTO local_users (username, hash, role, created_at) VALUES (?,?,?,?)',
            ('creator',
             hashlib.sha256('Asdf1234!'.encode()).hexdigest(),
             'admin',
             datetime.now(timezone.utc).isoformat()),
        )
    c.commit()


def log_action(action: str, detail: str = '', source: str = 'web'):
    from datetime import datetime, timezone
    conn().execute(
        'INSERT INTO audit_log (ts, action, detail, source) VALUES (?, ?, ?, ?)',
        (datetime.now(timezone.utc).isoformat(), action, detail, source)
    )
    conn().commit()
