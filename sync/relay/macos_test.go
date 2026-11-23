//go:build darwin

package relay

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"qi/sync/protocol"
)

// C3, C5: Mac 端（Swift）与其他设备经中转互相同步：网页级长文本完整到达，第三方设备按同一协议解密。
func TestMacClientInterop(t *testing.T) {
	root, _ := filepath.Abs("../..")
	bin := filepath.Join(t.TempDir(), "peer")
	build := exec.Command("swiftc", "-O", "-o", bin,
		filepath.Join(root, "macos/Sources/Sync.swift"), filepath.Join(root, "macos/Sources/Rime.swift"),
		filepath.Join(root, "tests/macos/main.swift"))
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		t.Fatal(err)
	}

	dir := t.TempDir()
	srv := httptest.NewServer(nil)
	defer srv.Close()
	code, _ := Init(dir, "ws://"+srv.Listener.Addr().String()+"/v1/ws")
	s, _ := New(dir)
	srv.Config.Handler = s.Handler()
	_, k, _ := protocol.ParsePairCode(code)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	other, _, err := websocket.Dial(ctx, "ws://"+srv.Listener.Addr().String()+"/v1/ws",
		&websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer " + k.AuthToken()}}})
	if err != nil {
		t.Fatal(err)
	}
	other.SetReadLimit(protocol.MaxFrame)

	long := strings.Repeat("这是一段从网页复制的长文本，含 emoji 🎉 与 API key sk-123。\n", 600)
	textFile := filepath.Join(t.TempDir(), "long.txt")
	os.WriteFile(textFile, []byte(long), 0o600)

	peer := exec.CommandContext(ctx, bin, code, textFile)
	out, _ := peer.StdoutPipe()
	peer.Stderr = os.Stderr
	if err := peer.Start(); err != nil {
		t.Fatal(err)
	}
	_, data, err := other.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var f protocol.Frame
	json.Unmarshal(data, &f)
	clip, err := k.Open(f)
	if err != nil || clip.Text != long || clip.From != "mac-a" {
		t.Fatalf("other device got %d bytes from %q: %v", len(clip.Text), clip.From, err)
	}
	sc := bufio.NewScanner(out)
	for sc.Scan() {
		line := sc.Text()
		t.Log(line)
		if strings.HasPrefix(line, "TIMEOUT") {
			t.Fatal(line)
		}
		if line == "READY" {
			fr, _ := k.Seal(protocol.Clip{ID: "o1", From: "phone", TS: time.Now().UnixMilli() + 1000, Text: "来自另一台设备"})
			b, _ := json.Marshal(fr)
			other.Write(ctx, websocket.MessageText, b)
		}
	}
	if err := peer.Wait(); err != nil {
		t.Fatal(err)
	}
}
