package client

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
)

type Store struct {
	Dir string
}

func NewStore(dir string) *Store {
	_ = os.MkdirAll(dir, 0o700)
	return &Store{Dir: dir}
}

// C5: 本机保存的同步组凭据（仅当前用户可读）。
func (s *Store) PairCode() string {
	b, err := os.ReadFile(filepath.Join(s.Dir, "pair.txt"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func (s *Store) SetPairCode(code string) error {
	p := filepath.Join(s.Dir, "pair.txt")
	if strings.TrimSpace(code) == "" {
		err := os.Remove(p)
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	if err := os.MkdirAll(s.Dir, 0o700); err != nil {
		return err
	}
	return os.WriteFile(p, []byte(strings.TrimSpace(code)), 0o600)
}

func (s *Store) DeviceID() string {
	p := filepath.Join(s.Dir, "device-id")
	if b, err := os.ReadFile(p); err == nil {
		if id := strings.TrimSpace(string(b)); id != "" {
			return id
		}
	}
	var raw [16]byte
	_, _ = rand.Read(raw[:])
	id := hex.EncodeToString(raw[:])
	_ = os.MkdirAll(s.Dir, 0o700)
	_ = os.WriteFile(p, []byte(id), 0o600)
	return id
}

func (s *Store) UpdateAvailable() string {
	b, err := os.ReadFile(filepath.Join(s.Dir, "update-available.txt"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func (s *Store) SetUpdateAvailable(version string) {
	p := filepath.Join(s.Dir, "update-available.txt")
	if strings.TrimSpace(version) == "" {
		_ = os.Remove(p)
		return
	}
	_ = os.MkdirAll(s.Dir, 0o700)
	_ = os.WriteFile(p, []byte(strings.TrimSpace(version)), 0o600)
}

func (s *Store) Welcomed() bool {
	_, err := os.Stat(filepath.Join(s.Dir, "welcomed"))
	return err == nil
}

func (s *Store) MarkWelcomed() {
	_ = os.MkdirAll(s.Dir, 0o700)
	_ = os.WriteFile(filepath.Join(s.Dir, "welcomed"), nil, 0o600)
}

func (s *Store) BetaUpdates() bool {
	_, err := os.Stat(filepath.Join(s.Dir, "beta-updates"))
	return err == nil
}

func (s *Store) SetBetaUpdates(on bool) {
	p := filepath.Join(s.Dir, "beta-updates")
	if !on {
		_ = os.Remove(p)
		return
	}
	_ = os.MkdirAll(s.Dir, 0o700)
	_ = os.WriteFile(p, nil, 0o600)
}
