package store

import (
	"database/sql"
	"fmt"
	"time"
)

// QueueItem represents a pending change in the offline queue.
type QueueItem struct {
	ID        int64
	Path      string
	Hash      []byte
	Action    string
	CreatedAt time.Time
	Attempts  int
	LastError string
}

// Enqueue adds a file change to the offline queue.
func (s *Store) Enqueue(path string, hash []byte, action string) error {
	_, err := s.db.Exec(
		"INSERT INTO queue (path, hash, action) VALUES (?, ?, ?)",
		path, hash, action,
	)
	return err
}

// Dequeue removes a successfully processed item from the queue.
func (s *Store) Dequeue(id int64) error {
	_, err := s.db.Exec("DELETE FROM queue WHERE id = ?", id)
	return err
}

// PendingCount returns the number of items in the queue.
func (s *Store) PendingCount() (int, error) {
	var count int
	err := s.db.QueryRow("SELECT COUNT(*) FROM queue").Scan(&count)
	return count, err
}

// PendingItems returns up to `limit` items from the queue, oldest first.
func (s *Store) PendingItems(limit int) ([]QueueItem, error) {
	rows, err := s.db.Query(
		"SELECT id, path, hash, action, created_at, attempts, COALESCE(last_error, '') FROM queue ORDER BY id ASC LIMIT ?",
		limit,
	)
	if err != nil {
		return nil, fmt.Errorf("query queue: %w", err)
	}
	defer rows.Close()

	var items []QueueItem
	for rows.Next() {
		var item QueueItem
		var createdStr string
		if err := rows.Scan(&item.ID, &item.Path, &item.Hash, &item.Action, &createdStr, &item.Attempts, &item.LastError); err != nil {
			return nil, fmt.Errorf("scan queue row: %w", err)
		}
		item.CreatedAt, _ = time.Parse(time.RFC3339, createdStr)
		items = append(items, item)
	}
	return items, rows.Err()
}

// MarkFailed increments the attempt counter and records the error.
func (s *Store) MarkFailed(id int64, errMsg string) error {
	_, err := s.db.Exec(
		"UPDATE queue SET attempts = attempts + 1, last_error = ? WHERE id = ?",
		errMsg, id,
	)
	return err
}

// PurgeOld removes queue items older than the given duration.
func (s *Store) PurgeOld(maxAge time.Duration) (int64, error) {
	cutoff := time.Now().Add(-maxAge).UTC().Format(time.RFC3339)
	result, err := s.db.Exec("DELETE FROM queue WHERE created_at < ?", cutoff)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// DeduplicateQueue removes older entries for the same path, keeping only the latest.
func (s *Store) DeduplicateQueue() error {
	_, err := s.db.Exec(`
		DELETE FROM queue WHERE id NOT IN (
			SELECT MAX(id) FROM queue GROUP BY path
		)
	`)
	return err
}

// NextItem returns the next unprocessed item, or nil if empty.
func (s *Store) NextItem() (*QueueItem, error) {
	items, err := s.PendingItems(1)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return nil, sql.ErrNoRows
	}
	return &items[0], nil
}
