package sync

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/eshe-huli/ringforge/edge/internal/client"
	"github.com/eshe-huli/ringforge/edge/internal/store"
)

const pushTimeout = 10 * time.Second

// UploadPending uploads all pending queue items to the cluster.
func UploadPending(c *client.Client, s *store.Store) (int, error) {
	// Deduplicate first
	if err := s.DeduplicateQueue(); err != nil {
		log.Printf("[sync] deduplicate warning: %v", err)
	}

	items, err := s.PendingItems(100)
	if err != nil {
		return 0, fmt.Errorf("get pending items: %w", err)
	}

	uploaded := 0
	for _, item := range items {
		var uploadErr error

		switch item.Action {
		case "upsert":
			data, err := os.ReadFile(item.Path)
			if err != nil {
				uploadErr = fmt.Errorf("read file %s: %w", item.Path, err)
			} else {
				uploadErr = UploadFile(c, item.Path, data, item.Hash)
			}
		case "delete":
			uploadErr = deleteRemote(c, item.Path)
		default:
			uploadErr = fmt.Errorf("unknown action: %s", item.Action)
		}

		if uploadErr != nil {
			log.Printf("[sync] upload failed for %s: %v", item.Path, uploadErr)
			_ = s.MarkFailed(item.ID, uploadErr.Error())
			continue
		}

		if err := s.Dequeue(item.ID); err != nil {
			log.Printf("[sync] dequeue failed for %d: %v", item.ID, err)
		}

		if item.Action == "upsert" {
			info, _ := os.Stat(item.Path)
			var size int64
			if info != nil {
				size = info.Size()
			}
			_ = s.RecordFile(item.Path, item.Hash, size)
		}

		uploaded++
	}

	return uploaded, nil
}

// UploadFile uploads a single file to the cluster via the sync channel.
func UploadFile(c *client.Client, key string, data, hash []byte) error {
	ch := client.NewChannel(c, "sync:files", map[string]interface{}{})

	if err := ch.Join(pushTimeout); err != nil {
		return fmt.Errorf("join sync channel: %w", err)
	}
	defer ch.Leave()

	payload := map[string]interface{}{
		"key":  key,
		"data": base64.StdEncoding.EncodeToString(data),
		"hash": fmt.Sprintf("%x", hash),
		"size": len(data),
	}

	reply, err := ch.Push("file:put", payload, pushTimeout)
	if err != nil {
		return fmt.Errorf("push file:put: %w", err)
	}

	var resp struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(reply.Payload, &resp); err != nil {
		return fmt.Errorf("unmarshal reply: %w", err)
	}
	if resp.Status != "ok" {
		return fmt.Errorf("server rejected upload: %s", string(reply.Payload))
	}

	return nil
}

func deleteRemote(c *client.Client, key string) error {
	ch := client.NewChannel(c, "sync:files", map[string]interface{}{})

	if err := ch.Join(pushTimeout); err != nil {
		return fmt.Errorf("join sync channel: %w", err)
	}
	defer ch.Leave()

	payload := map[string]interface{}{
		"key": key,
	}

	reply, err := ch.Push("file:delete", payload, pushTimeout)
	if err != nil {
		return fmt.Errorf("push file:delete: %w", err)
	}

	var resp struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(reply.Payload, &resp); err != nil {
		return fmt.Errorf("unmarshal reply: %w", err)
	}
	if resp.Status != "ok" {
		return fmt.Errorf("server rejected delete: %s", string(reply.Payload))
	}

	return nil
}
