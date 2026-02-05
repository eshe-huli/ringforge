//! Lightweight Merkle utilities for sync.
//!
//! Each document has a "root" = blake3(crdt_state).
//! We can compute a combined Merkle root over a sorted set of documents,
//! and diff two root-sets to find what needs sending / requesting.

use std::collections::{HashMap, HashSet};

/// Compute a single Merkle root from a sorted list of (doc_id, hash) pairs.
///
/// The algorithm: sort by doc_id, then iteratively hash pairs.
/// If the list has odd length the last element is promoted unchanged.
/// Repeat until one root remains.  An empty list yields all-zeros.
pub fn compute_root(pairs: &[(String, Vec<u8>)]) -> Vec<u8> {
    if pairs.is_empty() {
        return vec![0u8; 32];
    }

    let mut sorted = pairs.to_vec();
    sorted.sort_by(|a, b| a.0.cmp(&b.0));

    let mut layer: Vec<Vec<u8>> = sorted.into_iter().map(|(_, h)| h).collect();

    while layer.len() > 1 {
        let mut next = Vec::with_capacity((layer.len() + 1) / 2);
        let mut i = 0;
        while i + 1 < layer.len() {
            let mut hasher = blake3::Hasher::new();
            hasher.update(&layer[i]);
            hasher.update(&layer[i + 1]);
            next.push(hasher.finalize().as_bytes().to_vec());
            i += 2;
        }
        if i < layer.len() {
            // odd element promoted
            next.push(layer[i].clone());
        }
        layer = next;
    }

    layer.into_iter().next().unwrap()
}

/// Given local and remote root-sets, return `(to_send, to_request)`.
///
/// * `to_send`    – doc_ids the remote is missing or has a different hash for.
/// * `to_request` – doc_ids we are missing or have a different hash for.
pub fn diff_roots(
    local: &[(String, Vec<u8>)],
    remote: &[(String, Vec<u8>)],
) -> (Vec<String>, Vec<String>) {
    let local_map: HashMap<&str, &[u8]> = local.iter().map(|(k, v)| (k.as_str(), v.as_slice())).collect();
    let remote_map: HashMap<&str, &[u8]> = remote.iter().map(|(k, v)| (k.as_str(), v.as_slice())).collect();

    let all_keys: HashSet<&str> = local_map.keys().chain(remote_map.keys()).copied().collect();

    let mut to_send = Vec::new();
    let mut to_request = Vec::new();

    for key in all_keys {
        match (local_map.get(key), remote_map.get(key)) {
            (Some(lh), Some(rh)) if lh == rh => {
                // identical – nothing to do
            }
            (Some(_), Some(_)) => {
                // different – we send ours AND request theirs (conflict)
                to_send.push(key.to_string());
                to_request.push(key.to_string());
            }
            (Some(_), None) => {
                // we have it, they don't
                to_send.push(key.to_string());
            }
            (None, Some(_)) => {
                // they have it, we don't
                to_request.push(key.to_string());
            }
            (None, None) => unreachable!(),
        }
    }

    to_send.sort();
    to_request.sort();
    (to_send, to_request)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_empty_root() {
        assert_eq!(compute_root(&[]), vec![0u8; 32]);
    }

    #[test]
    fn test_single_root() {
        let h = blake3::hash(b"hello").as_bytes().to_vec();
        let root = compute_root(&[("doc1".into(), h.clone())]);
        assert_eq!(root, h);
    }

    #[test]
    fn test_diff_roots() {
        let h1 = blake3::hash(b"a").as_bytes().to_vec();
        let h2 = blake3::hash(b"b").as_bytes().to_vec();
        let h3 = blake3::hash(b"c").as_bytes().to_vec();

        let local = vec![
            ("doc1".into(), h1.clone()),
            ("doc2".into(), h2.clone()),
        ];
        let remote = vec![
            ("doc2".into(), h2.clone()),
            ("doc3".into(), h3.clone()),
        ];

        let (send, request) = diff_roots(&local, &remote);
        assert_eq!(send, vec!["doc1"]);
        assert_eq!(request, vec!["doc3"]);
    }
}
