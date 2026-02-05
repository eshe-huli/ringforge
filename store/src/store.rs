//! Content-addressed blob storage and document store backed by redb.

use anyhow::{Context, Result};
use redb::{Database, ReadableTable, TableDefinition};
use std::path::Path;
use tracing::{debug, instrument};

// ── Table definitions ─────────────────────────────────────────────────

/// blake3 hash (32 bytes) → raw blob bytes
const BLOBS: TableDefinition<&[u8], &[u8]> = TableDefinition::new("blobs");

/// document id (utf-8) → serialised metadata
const DOCUMENTS: TableDefinition<&str, &[u8]> = TableDefinition::new("documents");

/// document id (utf-8) → CRDT state bytes
const DOC_DATA: TableDefinition<&str, &[u8]> = TableDefinition::new("doc_data");

/// document id → blake3 hash of latest CRDT state (used for Merkle roots)
const DOC_HASHES: TableDefinition<&str, &[u8]> = TableDefinition::new("doc_hashes");

// ── Store ─────────────────────────────────────────────────────────────

pub struct Store {
    db: Database,
}

impl Store {
    /// Open (or create) the database at `dir/keyring.redb`.
    pub fn open(dir: &Path) -> Result<Self> {
        std::fs::create_dir_all(dir)
            .with_context(|| format!("creating data dir {}", dir.display()))?;
        let db_path = dir.join("keyring.redb");
        let db = Database::create(&db_path)
            .with_context(|| format!("opening database {}", db_path.display()))?;

        // Ensure all tables exist.
        let txn = db.begin_write()?;
        {
            let _ = txn.open_table(BLOBS)?;
            let _ = txn.open_table(DOCUMENTS)?;
            let _ = txn.open_table(DOC_DATA)?;
            let _ = txn.open_table(DOC_HASHES)?;
        }
        txn.commit()?;

        Ok(Self { db })
    }

    // ── Blobs ─────────────────────────────────────────────────────────

    /// Store `data`, return its blake3 hash (32 bytes).
    #[instrument(skip(self, data), fields(len = data.len()))]
    pub fn put_blob(&self, data: &[u8]) -> Result<Vec<u8>> {
        let hash = blake3::hash(data);
        let hash_bytes = hash.as_bytes();

        let txn = self.db.begin_write()?;
        {
            let mut table = txn.open_table(BLOBS)?;
            table.insert(hash_bytes.as_slice(), data)?;
        }
        txn.commit()?;

        debug!(hash = %hash, "blob stored");
        Ok(hash_bytes.to_vec())
    }

    /// Retrieve a blob by its blake3 hash.
    #[instrument(skip(self))]
    pub fn get_blob(&self, hash: &[u8]) -> Result<Option<Vec<u8>>> {
        let txn = self.db.begin_read()?;
        let table = txn.open_table(BLOBS)?;
        Ok(table.get(hash)?.map(|v| v.value().to_vec()))
    }

    /// Check whether a blob exists.
    pub fn has_blob(&self, hash: &[u8]) -> Result<bool> {
        let txn = self.db.begin_read()?;
        let table = txn.open_table(BLOBS)?;
        Ok(table.get(hash)?.is_some())
    }

    // ── Documents ─────────────────────────────────────────────────────

    /// Store or update a document (metadata + CRDT state).
    #[instrument(skip(self, meta, crdt_state))]
    pub fn put_document(&self, id: &str, meta: &[u8], crdt_state: &[u8]) -> Result<()> {
        let state_hash = blake3::hash(crdt_state);

        let txn = self.db.begin_write()?;
        {
            let mut docs = txn.open_table(DOCUMENTS)?;
            docs.insert(id, meta)?;

            let mut data = txn.open_table(DOC_DATA)?;
            data.insert(id, crdt_state)?;

            let mut hashes = txn.open_table(DOC_HASHES)?;
            hashes.insert(id, state_hash.as_bytes().as_slice())?;
        }
        txn.commit()?;

        debug!(id, hash = %state_hash, "document stored");
        Ok(())
    }

    /// Get a document by id.  Returns `(meta, crdt_state)`.
    pub fn get_document(&self, id: &str) -> Result<Option<(Vec<u8>, Vec<u8>)>> {
        let txn = self.db.begin_read()?;
        let docs = txn.open_table(DOCUMENTS)?;
        let data = txn.open_table(DOC_DATA)?;

        match (docs.get(id)?, data.get(id)?) {
            (Some(m), Some(d)) => Ok(Some((m.value().to_vec(), d.value().to_vec()))),
            _ => Ok(None),
        }
    }

    /// Delete a document and its data.
    pub fn delete_document(&self, id: &str) -> Result<bool> {
        let txn = self.db.begin_write()?;
        let existed;
        {
            let mut docs = txn.open_table(DOCUMENTS)?;
            existed = docs.remove(id)?.is_some();

            let mut data = txn.open_table(DOC_DATA)?;
            data.remove(id)?;

            let mut hashes = txn.open_table(DOC_HASHES)?;
            hashes.remove(id)?;
        }
        txn.commit()?;
        Ok(existed)
    }

    /// List all document ids.
    pub fn list_documents(&self) -> Result<Vec<String>> {
        let txn = self.db.begin_read()?;
        let docs = txn.open_table(DOCUMENTS)?;
        let mut ids = Vec::new();
        let iter = docs.iter()?;
        for entry in iter {
            let (k, _v) = entry?;
            ids.push(k.value().to_string());
        }
        Ok(ids)
    }

    // ── Hashes / roots ────────────────────────────────────────────────

    /// Get the state hash for a document.
    pub fn get_doc_hash(&self, id: &str) -> Result<Option<Vec<u8>>> {
        let txn = self.db.begin_read()?;
        let hashes = txn.open_table(DOC_HASHES)?;
        Ok(hashes.get(id)?.map(|v| v.value().to_vec()))
    }

    /// Get hashes for a set of document ids.
    pub fn get_doc_hashes(&self, ids: &[String]) -> Result<Vec<(String, Vec<u8>)>> {
        let txn = self.db.begin_read()?;
        let hashes = txn.open_table(DOC_HASHES)?;
        let mut out = Vec::new();
        for id in ids {
            if let Some(v) = hashes.get(id.as_str())? {
                out.push((id.clone(), v.value().to_vec()));
            }
        }
        Ok(out)
    }

    /// Get all document hashes (for full sync).
    pub fn all_doc_hashes(&self) -> Result<Vec<(String, Vec<u8>)>> {
        let txn = self.db.begin_read()?;
        let hashes = txn.open_table(DOC_HASHES)?;
        let mut out = Vec::new();
        let iter = hashes.iter()?;
        for entry in iter {
            let (k, v) = entry?;
            out.push((k.value().to_string(), v.value().to_vec()));
        }
        Ok(out)
    }
}
