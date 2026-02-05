package crypto

import (
	"io"
	"os"

	"github.com/zeebo/blake3"
)

// Blake3Hash computes a BLAKE3 hash of the given data.
func Blake3Hash(data []byte) []byte {
	h := blake3.New()
	h.Write(data)
	sum := h.Sum(nil)
	return sum
}

// Blake3HashFile computes a BLAKE3 hash of a file.
func Blake3HashFile(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	h := blake3.New()
	if _, err := io.Copy(h, f); err != nil {
		return nil, err
	}

	sum := h.Sum(nil)
	return sum, nil
}

// Blake3Verify checks if data matches the expected hash.
func Blake3Verify(data, expectedHash []byte) bool {
	actual := Blake3Hash(data)
	if len(actual) != len(expectedHash) {
		return false
	}
	for i := range actual {
		if actual[i] != expectedHash[i] {
			return false
		}
	}
	return true
}
