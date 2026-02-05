package crypto

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"fmt"
)

// GenerateEd25519Keypair generates a new Ed25519 keypair.
// Returns (publicKey, privateKey, error).
func GenerateEd25519Keypair() ([]byte, []byte, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, fmt.Errorf("generate ed25519 key: %w", err)
	}
	return []byte(pub), []byte(priv), nil
}

// Ed25519Sign signs data with the given private key.
func Ed25519Sign(privateKey, data []byte) ([]byte, error) {
	if len(privateKey) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("invalid private key size: %d (expected %d)", len(privateKey), ed25519.PrivateKeySize)
	}
	sig := ed25519.Sign(ed25519.PrivateKey(privateKey), data)
	return sig, nil
}

// Ed25519Verify verifies a signature with the given public key.
func Ed25519Verify(publicKey, data, sig []byte) bool {
	if len(publicKey) != ed25519.PublicKeySize {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(publicKey), data, sig)
}

// PublicKeyHex returns the hex-encoded public key.
func PublicKeyHex(pub []byte) string {
	return hex.EncodeToString(pub)
}

// ParseHexKey decodes a hex-encoded key.
func ParseHexKey(hexKey string) ([]byte, error) {
	return hex.DecodeString(hexKey)
}
