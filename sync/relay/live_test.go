package relay

import (
	"context"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"qi/sync/protocol"
)

// C3, C4, C5: 经用户的公网服务器实测（QI_PAIR_FILE 指向本机保存的配对码时运行）。
func TestLiveServer(t *testing.T) {
	path := os.Getenv("QI_PAIR_FILE")
	if path == "" {
		t.Skip("QI_PAIR_FILE not set")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	server, k, err := protocol.ParsePairCode(string(b))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	dial := func(token string) (*websocket.Conn, *http.Response, error) {
		c, resp, err := websocket.Dial(ctx, server, &websocket.DialOptions{
			HTTPHeader: http.Header{"Authorization": {"Bearer " + token}},
		})
		if c != nil {
			c.SetReadLimit(protocol.MaxFrame)
		}
		return c, resp, err
	}
	other, _ := protocol.NewKey()
	if _, resp, err := dial(other.AuthToken()); err == nil || resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("foreign device not rejected: %v %v", resp, err)
	}
	a, _, err := dial(k.AuthToken())
	if err != nil {
		t.Fatal(err)
	}
	c, _, err := dial(k.AuthToken())
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(time.Second)
	long := strings.Repeat("公网中转的网页级长文本测试。", 3000)
	send(t, a, k, long)
	for i := 0; i < 2; i++ {
		if recv(t, c, k).Text == long {
			return
		}
	}
	t.Fatal("long text not received")
}
