import Database from 'better-sqlite3';
import fs from 'node:fs';
import path from 'node:path';
import { config } from './config.js';

fs.mkdirSync(config.dataDir, { recursive: true });
const db = new Database(path.join(config.dataDir, 'drivepic.sqlite'));
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');
db.exec(`
  CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE COLLATE NOCASE,
    password_hash TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS images (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token TEXT NOT NULL UNIQUE,
    drive_file_id TEXT NOT NULL UNIQUE,
    original_name TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    width INTEGER,
    height INTEGER,
    size INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    expires_at TEXT,
    views INTEGER NOT NULL DEFAULT 0,
    last_viewed_at TEXT,
    deleted_at TEXT
  );
  CREATE INDEX IF NOT EXISTS idx_images_created_at ON images(created_at);
  CREATE INDEX IF NOT EXISTS idx_images_token ON images(token);
`);

export function getSetting(key: string) {
  return (db.prepare('SELECT value FROM settings WHERE key = ?').get(key) as { value: string } | undefined)?.value ?? null;
}

export function setSetting(key: string, value: string) {
  db.prepare(`INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)
    ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`)
    .run(key, value, new Date().toISOString());
}

export function isConfigured() {
  return getSetting('setup_complete') === '1';
}

export type ImageRow = {
  id: number; token: string; drive_file_id: string; original_name: string;
  mime_type: string; width: number | null; height: number | null; size: number;
  created_at: string; expires_at: string | null; views: number;
  last_viewed_at: string | null; deleted_at: string | null;
};

export default db;
