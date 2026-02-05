package sync

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"

	"github.com/eshe-huli/ringforge/edge/internal/client"
	"github.com/eshe-huli/ringforge/edge/internal/store"
)

// DownloadNew fetches new/updated files from the cluster.
func DownloadNew(c *client.Client, s *store.Store) (int, error) {
	ch := client.NewChannel(c, "sync:files", map[string]interface{}{})

	if err := ch.Join(pushTimeout); err != nil {
		return 0, fmt.Errorf("join sync channel: %w", err)
	}
	defer ch.Leave()

	// Request the manifest of files
	reply, err := ch.Push("file:list", map[string]interface{}{}, pushTimeout)
	if err != nil {
		return 0, fmt.Errorf("push file:list: %w", err)
	}

	var manifest struct {
		Status string `json:"status"`
		Files  []struct {
			Key  string `json:"key"`
			Hash string `json:"hash"`
			Size int64  `json:"size"`
		} `json:"files"`
	}
	if err := json.Unmarshal(reply.Payload, &manifest); err != nil {
		return 0, fmt.Errorf("unmarshal manifest: %w", err)
	}

	downloaded := 0
	for _, f := range manifest.Files {
		// Check if we already have this version
		localHash, err := s.FileHash(f.Key)
		if err != nil {
			log.Printf("[sync] hash lookup error for %s: %v", f.Key, err)
			continue
		}
		if fmt.Sprintf("%x", localHash) == f.Hash {
			continue // Already up to date
		}

		// Download the file
		data, err := DownloadFile(c, f.Key)
		if err != nil {
			log.Printf("[sync] download failed for %s: %v", f.Key, err)
			continue
		}

		// Write to disk
		dir := filepath.Dir(f.Key)
		if dir != "." {
			if err := os.MkdirAll(dir, 0755); err != nil {
				log.Printf("[sync] mkdir failed for %s: %v", dir, err)
				continue
			}
		}

		if err := os.WriteFile(f.Key, data, 0644); err != nil {
			log.Printf("[sync] write failed for %s: %v", f.Key, err)
			continue
		}

		// Record in local store
		hashBytes := []byte(f.Hash) // Simplified; real impl would decode hex
		_ = s.RecordFile(f.Key, hashBytes, int64(len(data)))

		log.Printf("[sync] downloaded: %s (%d bytes)", f.Key, len(data))
		downloaded++
	}

	return downloaded, nil
}

// DownloadFile downloads a single file from the cluster.
func DownloadFile(c *client.Client, key string) ([]byte, error) {
	ch := client.NewChannel(c, "sync:files", map[string]interface{}{})

	if err := ch.Join(pushTimeout); err != nil {
		return nil, fmt.Errorf("join sync channel: %w", err)
	}
	defer ch.Leave()

	reply, err := ch.Push("file:get", map[string]interface{}{"key": key}, pushTimeout)
	if err != nil {
		return nil, fmt.Errorf("push file:get: %w", err)
	}

	var resp struct {
		Status string `json:"status"`
		Data   string `json:"data"` // base64 encoded
	}
	if err := json.Unmarshal(reply.Payload, &resp); err != nil {
		return nil, fmt.Errorf("unmarshal file response: %w", err)
	}
	if resp.Status != "ok" {
		return nil, fmt.Errorf("server error: %s", string(reply.Payload))
	}

	data, err := base64.StdEncoding.DecodeString(resp.Data)
	if err != nil {
		return nil, fmt.Errorf("decode file data: %w", err)
	}

	return data, nil
}
