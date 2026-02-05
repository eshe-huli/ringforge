//! keyring-store — Elixir ↔ Rust storage port.
//!
//! Communicates via stdin/stdout using length-prefixed bincode frames:
//!   [4-byte big-endian length][bincode(ref_id: u64, Request)]
//!   [4-byte big-endian length][bincode(ref_id: u64, Response)]
//!
//! Logs go to stderr so they don't corrupt the binary protocol.

mod merkle;
mod protocol;
mod store;

use anyhow::{Context, Result};
use clap::Parser;
use protocol::{Change, RefId, Request, Response, Root};
use std::io::{self, Read, Write};
use std::path::PathBuf;
use store::Store;
use tracing::{debug, info};

// ── CLI ───────────────────────────────────────────────────────────────

#[derive(Parser, Debug)]
#[command(name = "keyring-store", about = "Content-addressed storage port for Keyring")]
struct Cli {
    /// Directory for the redb database.
    #[arg(long, default_value = "./data")]
    data_dir: PathBuf,
}

// ── Frame I/O ─────────────────────────────────────────────────────────

fn read_frame(r: &mut impl Read) -> Result<Option<Vec<u8>>> {
    let mut len_buf = [0u8; 4];
    match r.read_exact(&mut len_buf) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e.into()),
    }
    let len = u32::from_be_bytes(len_buf) as usize;
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf)
        .context("reading frame body")?;
    Ok(Some(buf))
}

fn write_frame(w: &mut impl Write, data: &[u8]) -> Result<()> {
    let len = (data.len() as u32).to_be_bytes();
    w.write_all(&len)?;
    w.write_all(data)?;
    w.flush()?;
    Ok(())
}

// ── Request dispatch ──────────────────────────────────────────────────

fn handle_request(store: &Store, req: Request) -> Response {
    match req {
        Request::PutBlob { data } => match store.put_blob(&data) {
            Ok(hash) => Response::BlobStored { hash },
            Err(e) => Response::Error { message: e.to_string() },
        },

        Request::GetBlob { hash } => match store.get_blob(&hash) {
            Ok(Some(data)) => Response::Blob { data },
            Ok(None) => Response::NotFound,
            Err(e) => Response::Error { message: e.to_string() },
        },

        Request::HasBlob { hash } => match store.has_blob(&hash) {
            Ok(exists) => Response::BlobExists { exists },
            Err(e) => Response::Error { message: e.to_string() },
        },

        Request::PutDocument { id, meta, crdt_state } => {
            match store.put_document(&id, &meta, &crdt_state) {
                Ok(()) => Response::Ok,
                Err(e) => Response::Error { message: e.to_string() },
            }
        }

        Request::GetDocument { id } => match store.get_document(&id) {
            Ok(Some((meta, crdt_state))) => Response::Document { id, meta, crdt_state },
            Ok(None) => Response::NotFound,
            Err(e) => Response::Error { message: e.to_string() },
        },

        Request::DeleteDocument { id } => match store.delete_document(&id) {
            Ok(true) => Response::Ok,
            Ok(false) => Response::NotFound,
            Err(e) => Response::Error { message: e.to_string() },
        },

        Request::ListDocuments => match store.list_documents() {
            Ok(ids) => Response::DocumentList { ids },
            Err(e) => Response::Error { message: e.to_string() },
        },

        Request::GetRoots { doc_ids } => {
            let hashes = if doc_ids.is_empty() {
                store.all_doc_hashes()
            } else {
                store.get_doc_hashes(&doc_ids)
            };
            match hashes {
                Ok(pairs) => {
                    let roots = pairs
                        .into_iter()
                        .map(|(doc_id, hash)| Root { doc_id, hash })
                        .collect();
                    Response::Roots { roots }
                }
                Err(e) => Response::Error { message: e.to_string() },
            }
        }

        Request::GetChanges { known_roots } => {
            // Compare known roots against local state to find what to send.
            match store.all_doc_hashes() {
                Ok(local_pairs) => {
                    // Build a set of known hashes for quick lookup.
                    let known_set: std::collections::HashSet<Vec<u8>> =
                        known_roots.into_iter().collect();
                    let mut changes = Vec::new();
                    for (doc_id, hash) in &local_pairs {
                        if !known_set.contains(hash) {
                            // Remote doesn't have this version — include the data.
                            match store.get_document(doc_id) {
                                Ok(Some((_meta, crdt_state))) => {
                                    changes.push(Change {
                                        doc_id: doc_id.clone(),
                                        data: crdt_state,
                                        hash: hash.clone(),
                                    });
                                }
                                Ok(None) => {} // deleted between reads, skip
                                Err(e) => {
                                    return Response::Error { message: e.to_string() };
                                }
                            }
                        }
                    }
                    Response::Changes { changes }
                }
                Err(e) => Response::Error { message: e.to_string() },
            }
        }

        Request::ApplyChanges { changes } => {
            for change in changes {
                // Only apply if we don't already have this exact version.
                match store.get_doc_hash(&change.doc_id) {
                    Ok(Some(existing)) if existing == change.hash => continue,
                    Ok(_) => {}
                    Err(e) => return Response::Error { message: e.to_string() },
                }
                // Store the CRDT state; meta is empty for remote changes
                // (the real app would merge CRDTs here).
                if let Err(e) = store.put_document(&change.doc_id, &[], &change.data) {
                    return Response::Error { message: e.to_string() };
                }
            }
            Response::Ok
        }
    }
}

// ── Main loop ─────────────────────────────────────────────────────────

fn main() -> Result<()> {
    // Logs to stderr so stdout stays clean for the binary protocol.
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(io::stderr)
        .init();

    let cli = Cli::parse();
    info!(data_dir = %cli.data_dir.display(), "keyring-store starting");

    let store = Store::open(&cli.data_dir)?;

    let mut stdin = io::stdin().lock();
    let mut stdout = io::stdout().lock();

    loop {
        let frame = match read_frame(&mut stdin)? {
            Some(f) => f,
            None => {
                info!("stdin closed, shutting down");
                break;
            }
        };

        let (ref_id, request): (RefId, Request) =
            bincode::deserialize(&frame).context("decoding request frame")?;

        debug!(ref_id, ?request, "received request");

        let response = handle_request(&store, request);

        debug!(ref_id, ?response, "sending response");

        let resp_bytes = bincode::serialize(&(ref_id, &response))?;
        write_frame(&mut stdout, &resp_bytes)?;
    }

    Ok(())
}
