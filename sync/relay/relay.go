// C4: 公网中转：保存最新一条密文并转发给其他在线设备。
package relay

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"qi/sync/protocol"
)

type Server struct {
	verifier string
	dataDir  string

	mu      sync.Mutex
	latest  []byte
	clients map[*websocket.Conn]chan []byte
}

func New(dataDir string) (*Server, error) {
	v, err := os.ReadFile(filepath.Join(dataDir, "verifier"))
	if err != nil {
		return nil, err
	}
	s := &Server{verifier: strings.TrimSpace(string(v)), dataDir: dataDir, clients: map[*websocket.Conn]chan []byte{}}
	s.latest, _ = os.ReadFile(filepath.Join(dataDir, "latest.json"))
	return s, nil
}

// Init C5: 生成配对密钥，服务器只留认证摘要，配对码交给用户自己的设备。
func Init(dataDir, serverURL string) (string, error) {
	k, err := protocol.NewKey()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(dataDir, "verifier"), []byte(protocol.Verifier(k.AuthToken())+"\n"), 0o600); err != nil {
		return "", err
	}
	os.Remove(filepath.Join(dataDir, "latest.json"))
	return protocol.PairCode(serverURL, k), nil
}

// authorized C5: 只允许持有配对密钥的设备收发。
func (s *Server) authorized(r *http.Request) bool {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(protocol.Verifier(token)), []byte(s.verifier)) == 1
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", s.serveWS)
	return mux
}

func (s *Server) serveWS(w http.ResponseWriter, r *http.Request) {
	if !s.authorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	c, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	c.SetReadLimit(protocol.MaxFrame)
	out := make(chan []byte, 8)
	s.mu.Lock()
	s.clients[c] = out
	if s.latest != nil {
		out <- s.latest
	}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.clients, c)
		s.mu.Unlock()
		c.CloseNow()
	}()

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	go func() {
		t := time.NewTicker(25 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case msg := <-out:
				wctx, wcancel := context.WithTimeout(ctx, 60*time.Second)
				err := c.Write(wctx, websocket.MessageText, msg)
				wcancel()
				if err != nil {
					cancel()
					return
				}
			case <-t.C:
				pctx, pcancel := context.WithTimeout(ctx, 20*time.Second)
				err := c.Ping(pctx)
				pcancel()
				if err != nil {
					cancel()
					return
				}
			}
		}
	}()

	for {
		_, data, err := c.Read(ctx)
		if err != nil {
			return
		}
		var f protocol.Frame
		if json.Unmarshal(data, &f) != nil || f.T != "clip" {
			continue
		}
		s.mu.Lock()
		s.latest = data
		for other, ch := range s.clients {
			if other == c {
				continue
			}
			select {
			case ch <- data:
			default:
				other.CloseNow()
			}
		}
		s.mu.Unlock()
		os.WriteFile(filepath.Join(s.dataDir, "latest.json"), data, 0o600)
	}
}
