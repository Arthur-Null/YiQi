// C4: 公网中转：保存最新一条密文并转发给同步组内其他在线设备。
package relay

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"qi/sync/protocol"
)

// C5: 临时密码限时、限次数
const (
	inviteTTL        = 5 * time.Minute
	inviteAttempts   = 5
	setupAttempts    = 10
	joinReplyTimeout = 30 * time.Second
)

type invite struct {
	conn     *websocket.Conn
	out      chan []byte
	expires  time.Time
	attempts int
}

type Server struct {
	dataDir string

	mu         sync.Mutex
	verifier   string
	setupCode  string
	setupFails int
	latest     []byte
	clients    map[*websocket.Conn]chan []byte
	invite     *invite
	joins      map[string]chan string
}

func New(dataDir string) (*Server, error) {
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return nil, err
	}
	v, _ := os.ReadFile(filepath.Join(dataDir, "verifier"))
	s := &Server{
		verifier: strings.TrimSpace(string(v)), dataDir: dataDir,
		clients: map[*websocket.Conn]chan []byte{}, joins: map[string]chan string{},
	}
	s.latest, _ = os.ReadFile(filepath.Join(dataDir, "latest.json"))
	if s.verifier == "" {
		s.setupCode = SetupCode(dataDir)
		if s.setupCode == "" {
			s.newSetupCode()
		}
		log.Printf("同步组尚未注册，第一台设备使用临时密码：%s", s.setupCode)
	}
	return s, nil
}

// newSetupCode C5: 第一台设备注册用的临时密码，只在服务器上生成和查看。
func (s *Server) newSetupCode() {
	s.setupCode = protocol.NewCode()
	s.setupFails = 0
	os.WriteFile(filepath.Join(s.dataDir, "setup-code"), []byte(s.setupCode+"\n"), 0o600)
}

// SetupCode C5: 读出当前的注册临时密码（供部署者在服务器上查看）。
func SetupCode(dataDir string) string {
	c, _ := os.ReadFile(filepath.Join(dataDir, "setup-code"))
	return strings.TrimSpace(string(c))
}

// Reset C5: 所有设备都丢失时，在服务器上清除同步组，重新生成注册临时密码。
func Reset(dataDir string) (string, error) {
	os.Remove(filepath.Join(dataDir, "latest.json"))
	if err := os.Remove(filepath.Join(dataDir, "verifier")); err != nil && !os.IsNotExist(err) {
		return "", err
	}
	s := &Server{dataDir: dataDir}
	s.newSetupCode()
	return s.setupCode, nil
}

// authorized C5: 只允许同步组内的设备收发。
func (s *Server) authorized(r *http.Request) bool {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return false
	}
	s.mu.Lock()
	v := s.verifier
	s.mu.Unlock()
	if v == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(protocol.Verifier(token)), []byte(v)) == 1
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", s.serveWS)
	mux.HandleFunc("/v1/claim", s.serveClaim)
	mux.HandleFunc("/v1/join", s.serveJoin)
	return mux
}

type claimRequest struct {
	Code     string `json:"code"`
	Verifier string `json:"v"`
}

// serveClaim C5, C7: 第一台设备凭服务器生成的临时密码注册同步组；注册后临时密码作废，再注册一律拒绝。
func (s *Server) serveClaim(w http.ResponseWriter, r *http.Request) {
	var req claimRequest
	if r.Method != http.MethodPost || json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&req) != nil ||
		len(req.Verifier) != 43 {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.verifier != "" {
		http.Error(w, "already registered", http.StatusConflict)
		return
	}
	if subtle.ConstantTimeCompare([]byte(req.Code), []byte(s.setupCode)) != 1 {
		s.setupFails++
		if s.setupFails >= setupAttempts {
			s.newSetupCode()
			log.Printf("注册临时密码输错次数过多，已更换为：%s", s.setupCode)
		}
		http.Error(w, "wrong code", http.StatusForbidden)
		return
	}
	if err := os.WriteFile(filepath.Join(s.dataDir, "verifier"), []byte(req.Verifier+"\n"), 0o600); err != nil {
		http.Error(w, "storage", http.StatusInternalServerError)
		return
	}
	os.Remove(filepath.Join(s.dataDir, "setup-code"))
	s.verifier = req.Verifier
	s.setupCode = ""
	w.WriteHeader(http.StatusOK)
}

// serveJoin C5: 新设备提交一次性公钥，服务器转给正在「添加设备」的那台设备，再把它的答复带回来。
func (s *Server) serveJoin(w http.ResponseWriter, r *http.Request) {
	var f protocol.Frame
	if r.Method != http.MethodPost || json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&f) != nil ||
		f.D == "" {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	inv := s.invite
	if inv == nil || time.Now().After(inv.expires) {
		s.invite = nil
		s.mu.Unlock()
		http.Error(w, "no invite", http.StatusNotFound)
		return
	}
	inv.attempts++
	if inv.attempts > inviteAttempts {
		s.invite = nil
		s.mu.Unlock()
		http.Error(w, "too many attempts", http.StatusTooManyRequests)
		return
	}
	id := randomID()
	reply := make(chan string, 1)
	s.joins[id] = reply
	msg, _ := json.Marshal(protocol.Frame{T: "join", D: f.D, J: id})
	select {
	case inv.out <- msg:
	default:
	}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.joins, id)
		s.mu.Unlock()
	}()
	select {
	case d := <-reply:
		json.NewEncoder(w).Encode(protocol.Frame{T: "join-ok", D: d})
	case <-time.After(joinReplyTimeout):
		http.Error(w, "no reply", http.StatusGatewayTimeout)
	case <-r.Context().Done():
	}
}

func randomID() string {
	b := make([]byte, 12)
	rand.Read(b)
	return hex.EncodeToString(b)
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
		if s.invite != nil && s.invite.conn == c {
			s.invite = nil
		}
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
		if json.Unmarshal(data, &f) != nil {
			continue
		}
		switch f.T {
		case "invite":
			s.mu.Lock()
			s.invite = &invite{conn: c, out: out, expires: time.Now().Add(inviteTTL)}
			s.mu.Unlock()
		case "invite-end":
			s.mu.Lock()
			if s.invite != nil && s.invite.conn == c {
				s.invite = nil
			}
			s.mu.Unlock()
		case "join-ok":
			s.mu.Lock()
			if ch, ok := s.joins[f.J]; ok && s.invite != nil && s.invite.conn == c {
				select {
				case ch <- f.D:
				default:
				}
			}
			s.mu.Unlock()
		case "clip":
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
}
