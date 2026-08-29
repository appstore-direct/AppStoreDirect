package main

import (
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"sync"

	cookiejar "github.com/juju/persistent-cookiejar"
	ipahttp "github.com/majd/ipatool/v2/pkg/http"
)

// ipatool's AppStore client takes its Keychain, CookieJar, Machine and
// OperatingSystem as interfaces. Substituting our own here is what lets us use its
// Apple-protocol code without forking it, and is why the sidecar never touches the
// user's real keychain or writes credentials anywhere the app does not control.

// memoryKeychain satisfies ipatool's keychain.Keychain but keeps everything in RAM
// for the life of one process. Persistence is the Swift side's job: it owns the
// macOS Keychain item, so credentials have exactly one home.
type memoryKeychain struct {
	mu     sync.Mutex
	values map[string][]byte
}

func newMemoryKeychain() *memoryKeychain {
	return &memoryKeychain{values: map[string][]byte{}}
}

func (k *memoryKeychain) Get(key string) ([]byte, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	value, ok := k.values[key]
	if !ok {
		return nil, errors.New("item not found")
	}
	return value, nil
}

func (k *memoryKeychain) Set(key string, data []byte) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.values[key] = append([]byte(nil), data...)
	return nil
}

func (k *memoryKeychain) Remove(key string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	delete(k.values, key)
	return nil
}

// zero overwrites every stored value before the process exits.
func (k *memoryKeychain) zero() {
	k.mu.Lock()
	defer k.mu.Unlock()
	for key, value := range k.values {
		for i := range value {
			value[i] = 0
		}
		delete(k.values, key)
	}
}

// sessionJar wraps juju/persistent-cookiejar, which ipatool's HTTP client expects
// (net/http.CookieJar plus Save). Its on-disk file lives in a private temp
// directory that is removed when the operation ends; the authoritative copy is the
// base64 blob handed back to Swift for the Keychain.
type sessionJar struct {
	*cookiejar.Jar
	path string
	dir  string
}

func newSessionJar(encoded string) (*sessionJar, error) {
	dir, err := os.MkdirTemp("", "asd-session-")
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		os.RemoveAll(dir)
		return nil, err
	}

	path := filepath.Join(dir, "cookies.json")
	if encoded != "" {
		raw, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			os.RemoveAll(dir)
			return nil, errors.New("stored session is corrupt")
		}
		if err := os.WriteFile(path, raw, 0o600); err != nil {
			os.RemoveAll(dir)
			return nil, err
		}
	}

	jar, err := cookiejar.New(&cookiejar.Options{Filename: path})
	if err != nil {
		os.RemoveAll(dir)
		return nil, err
	}
	return &sessionJar{Jar: jar, path: path, dir: dir}, nil
}

// export flushes the jar and returns it as base64 for storage in the Keychain.
func (j *sessionJar) export() (string, error) {
	if err := j.Jar.Save(); err != nil {
		return "", err
	}
	raw, err := os.ReadFile(j.path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	return base64.StdEncoding.EncodeToString(raw), nil
}

// close scrubs the temp copy. Overwriting before unlinking keeps the cookies from
// lingering in free blocks.
func (j *sessionJar) close() {
	if info, err := os.Stat(j.path); err == nil {
		if file, err := os.OpenFile(j.path, os.O_WRONLY, 0o600); err == nil {
			zeros := make([]byte, info.Size())
			_, _ = file.Write(zeros)
			_ = file.Sync()
			_ = file.Close()
		}
	}
	_ = os.RemoveAll(j.dir)
}

// Compile-time confirmation that the jar still satisfies what ipatool's HTTP
// client requires: net/http.CookieJar plus Save.
var _ ipahttp.CookieJar = (*sessionJar)(nil)
