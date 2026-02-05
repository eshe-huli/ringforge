package client

import (
	"crypto/ed25519"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"time"
)

// TokenManager handles authentication tokens and Ed25519 signing.
type TokenManager struct {
	privateKey ed25519.PrivateKey
	publicKey  ed25519.PublicKey
	token      string
}

// NewTokenManager creates a TokenManager from a keyfile or raw token.
func NewTokenManager(keyPath, token string) (*TokenManager, error) {
	tm := &TokenManager{token: strings.TrimSpace(token)}

	if keyPath != "" {
		keyData, err := os.ReadFile(keyPath)
		if err != nil {
			return nil, fmt.Errorf("read key %s: %w", keyPath, err)
		}
		if len(keyData) < ed25519.PrivateKeySize {
			return nil, fmt.Errorf("invalid private key (too short)")
		}
		tm.privateKey = ed25519.PrivateKey(keyData[:ed25519.PrivateKeySize])
		tm.publicKey = tm.privateKey.Public().(ed25519.PublicKey)
	}

	return tm, nil
}

// Token returns the bearer token.
func (tm *TokenManager) Token() string {
	return tm.token
}

// Sign produces an Ed25519 signature over the given data.
func (tm *TokenManager) Sign(data []byte) ([]byte, error) {
	if tm.privateKey == nil {
		return nil, fmt.Errorf("no private key loaded")
	}
	return ed25519.Sign(tm.privateKey, data), nil
}

// PublicKeyHex returns the hex-encoded public key.
func (tm *TokenManager) PublicKeyHex() string {
	if tm.publicKey == nil {
		return ""
	}
	return hex.EncodeToString(tm.publicKey)
}

// SignChallenge signs a server challenge (timestamp + nonce).
func (tm *TokenManager) SignChallenge(challenge string) (string, error) {
	sig, err := tm.Sign([]byte(challenge))
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(sig), nil
}

// IsExpired checks if the token timestamp is beyond maxAge.
func IsExpired(issuedAt time.Time, maxAge time.Duration) bool {
	return time.Since(issuedAt) > maxAge
}
