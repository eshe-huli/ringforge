//! Wire protocol types for the Elixir ↔ Rust port.
//!
//! Every frame on stdin/stdout is:
//!   [4-byte big-endian length] [bincode payload]
//!
//! Payload is always (ref_id: u64, Request) or (ref_id: u64, Response).

use serde::{Deserialize, Serialize};

/// Unique per-request id so Elixir can match replies.
pub type RefId = u64;

// ── Requests ──────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub enum Request {
    /// Store a blob; returns its blake3 hash.
    PutBlob { data: Vec<u8> },

    /// Retrieve a blob by hash.
    GetBlob { hash: Vec<u8> },

    /// Check if a blob exists.
    HasBlob { hash: Vec<u8> },

    /// Store / update a document.
    PutDocument {
        id: String,
        meta: Vec<u8>,
        crdt_state: Vec<u8>,
    },

    /// Get a document by id.
    GetDocument { id: String },

    /// Delete a document by id.
    DeleteDocument { id: String },

    /// List all document ids.
    ListDocuments,

    /// Return the Merkle roots for the given document ids.
    GetRoots { doc_ids: Vec<String> },

    /// Return changes since a set of known roots.
    GetChanges { known_roots: Vec<Vec<u8>> },

    /// Apply a batch of changes from a remote peer.
    ApplyChanges { changes: Vec<Change> },
}

// ── Responses ─────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub enum Response {
    Ok,

    Blob {
        data: Vec<u8>,
    },

    BlobStored {
        hash: Vec<u8>,
    },

    BlobExists {
        exists: bool,
    },

    Document {
        id: String,
        meta: Vec<u8>,
        crdt_state: Vec<u8>,
    },

    DocumentList {
        ids: Vec<String>,
    },

    NotFound,

    Roots {
        roots: Vec<Root>,
    },

    Changes {
        changes: Vec<Change>,
    },

    SyncDiff {
        to_send: Vec<Vec<u8>>,
        to_request: Vec<Vec<u8>>,
    },

    Error {
        message: String,
    },
}

// ── Auxiliary types ───────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Root {
    pub doc_id: String,
    pub hash: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Change {
    pub doc_id: String,
    pub data: Vec<u8>,
    pub hash: Vec<u8>,
}
