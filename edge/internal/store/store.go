package store

import (
	"database/sql"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

// Store manages the local SQLite database for Keyring state.
type Store struct {
	db *sql.DB
}

// Open opens (or creates) a SQLite database at the given path.
func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open sqlite %s: %w", path, err)
	}

	// WAL mode for better concurrent performance
	if _, err := db.Exec("PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, fmt.Errorf("set WAL mode: %w", err)
	}

	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}

	return s, nil
}

// Close closes the database.
func (s *Store) Close() error {
	return s.db.Close()
}

func (s *Store) migrate() error {
	migrations := []string{
		`CREATE TABLE IF NOT EXISTS queue (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			path TEXT NOT NULL,
			hash BLOB,
			action TEXT NOT NULL DEFAULT 'upsert',
			created_at TEXT NOT NULL DEFAULT (datetime('now')),
			attempts INTEGER NOT NULL DEFAULT 0,
			last_error TEXT
		)`,
		`CREATE TABLE IF NOT EXISTS files (
			path TEXT PRIMARY KEY,
			hash BLOB NOT NULL,
			size INTEGER NOT NULL,
			synced_at TEXT NOT NULL,
			version INTEGER NOT NULL DEFAULT 1
		)`,
		`CREATE TABLE IF NOT EXISTS meta (
			key TEXT PRIMARY KEY,
			value TEXT NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS idx_queue_created ON queue(created_at)`,
		`CREATE INDEX IF NOT EXISTS idx_files_hash ON files(hash)`,
	}

	for _, m := range migrations {
		if _, err := s.db.Exec(m); err != nil {
			return fmt.Errorf("migration: %w\nSQL: %s", err, m)
		}
	}
	return nil
}

// SetMeta stores a key-value pair.
func (s *Store) SetMeta(key, value string) error {
	_, err := s.db.Exec(
		"INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
		key, value,
	)
	return err
}

// GetMeta retrieves a value by key.
func (s *Store) GetMeta(key string) (string, error) {
	var value string
	err := s.db.QueryRow("SELECT value FROM meta WHERE key = ?", key).Scan(&value)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return value, err
}

// RecordFile records a synced file's metadata.
func (s *Store) RecordFile(path string, hash []byte, size int64) error {
	_, err := s.db.Exec(
		`INSERT OR REPLACE INTO files (path, hash, size, synced_at, version) 
		 VALUES (?, ?, ?, ?, COALESCE((SELECT version FROM files WHERE path = ?), 0) + 1)`,
		path, hash, size, time.Now().UTC().Format(time.RFC3339), path,
	)
	return err
}

// FileHash returns the last known hash for a file path.
func (s *Store) FileHash(path string) ([]byte, error) {
	var hash []byte
	err := s.db.QueryRow("SELECT hash FROM files WHERE path = ?", path).Scan(&hash)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return hash, err
}
