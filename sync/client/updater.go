package client

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const ReleasesURL = "https://api.github.com/repos/Arthur-Null/YiQi/releases?per_page=10"

type Release struct {
	Version     string `json:"version"`
	DownloadURL string `json:"download_url"`
}

func IsNewer(a, b string) bool {
	xs := strings.Split(strings.TrimPrefix(strings.TrimSpace(a), "v"), ".")
	ys := strings.Split(strings.TrimPrefix(strings.TrimSpace(b), "v"), ".")
	n := max(len(xs), len(ys))
	for i := 0; i < n; i++ {
		var p, q int
		if i < len(xs) {
			p, _ = strconv.Atoi(xs[i])
		}
		if i < len(ys) {
			q, _ = strconv.Atoi(ys[i])
		}
		if p != q {
			return p > q
		}
	}
	return false
}

type ghRelease struct {
	TagName    string `json:"tag_name"`
	Draft      bool   `json:"draft"`
	Prerelease bool   `json:"prerelease"`
	Assets     []struct {
		Name               string `json:"name"`
		BrowserDownloadURL string `json:"browser_download_url"`
	} `json:"assets"`
}

func CheckUpdate(ctx context.Context, hc *http.Client, apiURL, currentVersion, assetName string, includePrerelease bool) (*Release, bool) {
	if hc == nil {
		hc = &http.Client{Timeout: 20 * time.Second}
	}
	if apiURL == "" {
		apiURL = ReleasesURL
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, apiURL, nil)
	if err != nil {
		return nil, false
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	resp, err := hc.Do(req)
	if err != nil {
		return nil, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, false
	}
	var list []ghRelease
	if err := json.NewDecoder(resp.Body).Decode(&list); err != nil {
		return nil, false
	}
	var found *Release
	for _, r := range list {
		if r.Draft || (r.Prerelease && !includePrerelease) {
			continue
		}
		for _, a := range r.Assets {
			if a.Name != assetName || a.BrowserDownloadURL == "" {
				continue
			}
			v := strings.TrimPrefix(r.TagName, "v")
			if found == nil || IsNewer(v, found.Version) {
				found = &Release{Version: v, DownloadURL: a.BrowserDownloadURL}
			}
		}
	}
	if found != nil && IsNewer(found.Version, currentVersion) {
		return found, true
	}
	return nil, true
}

func DownloadRelease(ctx context.Context, hc *http.Client, r Release, dest string) error {
	if hc == nil {
		hc = &http.Client{Timeout: 10 * time.Minute}
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, r.DownloadURL, nil)
	if err != nil {
		return err
	}
	resp, err := hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	part := dest + ".part"
	f, err := os.Create(part)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		_ = os.Remove(part)
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(part)
		return err
	}
	_ = os.Remove(dest)
	return os.Rename(part, dest)
}
