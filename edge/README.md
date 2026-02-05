# Keyring Go Edge Agent

Local agent that watches files, computes BLAKE3 hashes, and syncs to the Keyring cluster via Phoenix Channels over WebSocket.

## Build

```bash
go build -o keyring ./cmd/keyring
```

## Usage

```bash
# Initialize a directory
./keyring init ~/vault

# Watch for changes and sync
./keyring watch ~/vault --server ws://cluster.keyring.dev/socket/websocket

# One-shot sync
./keyring sync

# Put/get individual files
./keyring put notes/daily.md ./daily.md
./keyring get notes/daily.md
```

## Architecture

```
cmd/keyring/           — CLI entry point (cobra)
internal/
  client/              — WebSocket + Phoenix Channel protocol
  watcher/             — fsnotify file watcher + debounce
  store/               — SQLite local store + offline queue
  sync/                — Upload/download logic
  crypto/              — BLAKE3 hashing, Ed25519 signing
```

## Features

- **Phoenix Channel protocol** — join/leave, push/reply, heartbeat, reconnect with exponential backoff
- **File watching** — recursive fsnotify with 500ms debounce
- **Offline queue** — SQLite-backed queue for changes made while disconnected
- **BLAKE3 hashing** — fast content-addressed deduplication
- **Ed25519 signing** — keypair generation and challenge signing
