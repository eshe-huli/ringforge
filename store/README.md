# keyring-store

Content-addressed storage port for [Keyring](https://github.com/eshe-huli/keyring). Communicates with Elixir via stdin/stdout using length-prefixed bincode frames.

## Protocol

Every frame is `[4-byte big-endian length][bincode payload]`.

- **Request**: `(ref_id: u64, Request)`
- **Response**: `(ref_id: u64, Response)`

### Operations

| Request | Response | Description |
|---------|----------|-------------|
| `PutBlob { data }` | `BlobStored { hash }` | Store blob, get blake3 hash |
| `GetBlob { hash }` | `Blob { data }` / `NotFound` | Retrieve blob |
| `HasBlob { hash }` | `BlobExists { exists }` | Check existence |
| `PutDocument { id, meta, crdt_state }` | `Ok` | Store/update document |
| `GetDocument { id }` | `Document { id, meta, crdt_state }` / `NotFound` | Get document |
| `DeleteDocument { id }` | `Ok` / `NotFound` | Delete document |
| `ListDocuments` | `DocumentList { ids }` | List all doc ids |
| `GetRoots { doc_ids }` | `Roots { roots }` | Merkle roots for sync |
| `GetChanges { known_roots }` | `Changes { changes }` | Changes since known state |
| `ApplyChanges { changes }` | `Ok` | Apply remote changes |

## Build

```bash
cargo build --release
```

## Usage

```bash
./target/release/keyring-store --data-dir /path/to/storage
```

Logs go to stderr. The binary reads requests from stdin and writes responses to stdout.

## Storage

Uses [redb](https://github.com/cberner/redb) with tables:
- `blobs`: blake3 hash → raw bytes
- `documents`: doc id → metadata
- `doc_data`: doc id → CRDT state
- `doc_hashes`: doc id → blake3(crdt_state)
