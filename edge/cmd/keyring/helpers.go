package main

// Thin wrappers so main.go stays readable. Real logic lives in internal/.

import (
	"time"

	"github.com/eshe-huli/ringforge/edge/internal/client"
	"github.com/eshe-huli/ringforge/edge/internal/crypto"
	"github.com/eshe-huli/ringforge/edge/internal/store"
	ksync "github.com/eshe-huli/ringforge/edge/internal/sync"
	"github.com/eshe-huli/ringforge/edge/internal/watcher"
)

func generateKeypair() (pub, priv []byte, err error) {
	return crypto.GenerateEd25519Keypair()
}

func openStore(path string) (*store.Store, error) {
	return store.Open(path)
}

func newClient(url, token string) (*client.Client, error) {
	return client.New(url, token)
}

func computeBlake3(data []byte) []byte {
	return crypto.Blake3Hash(data)
}

func uploadPending(c *client.Client, s *store.Store) (int, error) {
	return ksync.UploadPending(c, s)
}

func downloadNew(c *client.Client, s *store.Store) (int, error) {
	return ksync.DownloadNew(c, s)
}

func uploadFile(c *client.Client, key string, data, hash []byte) error {
	return ksync.UploadFile(c, key, data, hash)
}

func downloadFile(c *client.Client, key string) ([]byte, error) {
	return ksync.DownloadFile(c, key)
}

func watchDirs(dirs []string, debounce time.Duration, s *store.Store) error {
	return watcher.Watch(dirs, debounce, s)
}
