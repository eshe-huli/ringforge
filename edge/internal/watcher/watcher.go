package watcher

import (
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/eshe-huli/ringforge/edge/internal/crypto"
	"github.com/eshe-huli/ringforge/edge/internal/store"
	"github.com/fsnotify/fsnotify"
)

// Watch starts watching the given directories for file changes.
// Changes are debounced and queued in the store.
func Watch(dirs []string, debounceWindow time.Duration, s *store.Store) error {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return fmt.Errorf("create watcher: %w", err)
	}
	defer w.Close()

	// Add directories (recursively)
	for _, dir := range dirs {
		if err := addRecursive(w, dir); err != nil {
			return fmt.Errorf("watch %s: %w", dir, err)
		}
		log.Printf("[watcher] watching %s", dir)
	}

	debouncer := NewDebouncer(debounceWindow)
	defer debouncer.Stop()

	// Process debounced events
	go func() {
		for path := range debouncer.Output() {
			if err := processChange(path, s); err != nil {
				log.Printf("[watcher] error processing %s: %v", path, err)
			}
		}
	}()

	// Signal handling for graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	for {
		select {
		case event, ok := <-w.Events:
			if !ok {
				return nil
			}

			// Skip .keyring directory
			if isKeyringPath(event.Name) {
				continue
			}

			if event.Has(fsnotify.Write) || event.Has(fsnotify.Create) || event.Has(fsnotify.Remove) || event.Has(fsnotify.Rename) {
				debouncer.Trigger(event.Name)
			}

			// Watch new directories
			if event.Has(fsnotify.Create) {
				info, err := os.Stat(event.Name)
				if err == nil && info.IsDir() {
					_ = addRecursive(w, event.Name)
				}
			}

		case err, ok := <-w.Errors:
			if !ok {
				return nil
			}
			log.Printf("[watcher] error: %v", err)

		case <-sigCh:
			log.Println("[watcher] shutting down")
			return nil
		}
	}
}

func addRecursive(w *fsnotify.Watcher, root string) error {
	return filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // skip inaccessible
		}
		if info.IsDir() {
			if info.Name() == ".keyring" || info.Name() == ".git" {
				return filepath.SkipDir
			}
			return w.Add(path)
		}
		return nil
	})
}

func processChange(path string, s *store.Store) error {
	info, err := os.Stat(path)
	if os.IsNotExist(err) {
		// File was deleted
		log.Printf("[watcher] deleted: %s", path)
		return s.Enqueue(path, nil, "delete")
	}
	if err != nil {
		return fmt.Errorf("stat %s: %w", path, err)
	}

	if info.IsDir() {
		return nil
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read %s: %w", path, err)
	}

	hash := crypto.Blake3Hash(data)
	log.Printf("[watcher] changed: %s (blake3:%x, %d bytes)", path, hash[:8], len(data))

	return s.Enqueue(path, hash, "upsert")
}

func isKeyringPath(path string) bool {
	for _, part := range filepath.SplitList(path) {
		if part == ".keyring" {
			return true
		}
	}
	// Simpler check
	abs, _ := filepath.Abs(path)
	matched, _ := filepath.Match("*/.keyring/*", abs)
	return matched || filepath.Base(filepath.Dir(path)) == ".keyring"
}
