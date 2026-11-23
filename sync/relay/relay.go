// C4: 公网中转：保存最新一条密文并转发给同步组内其他在线设备。
package relay

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/coder/websocket"

	"qi/sync/protocol"
)

// C5: 临时密码限时、限次数
const (
	inviteTTL        = 5 * time.Minute
	inviteAttempts   = 5
	setupAttempts    = 10
	SetupCodeTTL     = 10 * time.Minute
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
	s := &Server{
		verifier: readVerifier(dataDir), dataDir: dataDir,
		clients: map[*websocket.Conn]chan []byte{}, joins: map[string]chan string{},
	}
	s.latest, _ = os.ReadFile(filepath.Join(dataDir, "latest.json"))
	go s.watchVerifier()
	return s, nil
}

func readVerifier(dataDir string) string {
	v, _ := os.ReadFile(filepath.Join(dataDir, "verifier"))
	return strings.TrimSpace(string(v))
}

// watchVerifier C5: 在服务器上重置同步组后，已连接的旧设备立即断开，无需重启服务。
func (s *Server) watchVerifier() {
	for range time.Tick(2 * time.Second) {
		s.reloadVerifier()
	}
}

func (s *Server) reloadVerifier() {
	v := readVerifier(s.dataDir)
	s.mu.Lock()
	if v == s.verifier {
		s.mu.Unlock()
		return
	}
	s.verifier = v
	s.latest = nil
	s.invite = nil
	conns := make([]*websocket.Conn, 0, len(s.clients))
	for c := range s.clients {
		conns = append(conns, c)
	}
	s.mu.Unlock()
	for _, c := range conns {
		c.CloseNow()
	}
}

// NewSetupCode C5: 在服务器上现场生成第一台设备注册用的临时密码，ttl 后失效；同步组已注册时拒绝生成。
func NewSetupCode(dataDir string, ttl time.Duration) (string, error) {
	if readVerifier(dataDir) != "" {
		return "", ErrRegistered
	}
	code := protocol.NewCode()
	line := code + " " + strconv.FormatInt(time.Now().Add(ttl).Unix(), 10) + "\n"
	p := filepath.Join(dataDir, "setup-code")
	if err := os.WriteFile(p, []byte(line), 0o600); err != nil {
		return "", err
	}
	// C5: 命令可能以 root 运行，文件需归服务进程（数据目录的所有者）可读
	if st, err := os.Stat(dataDir); err == nil {
		if sys, ok := st.Sys().(*syscall.Stat_t); ok {
			os.Chown(p, int(sys.Uid), int(sys.Gid))
		}
	}
	return code, nil
}

var ErrRegistered = errors.New("sync group already registered")

// currentSetupCode C5: 读出仍在有效期内的注册临时密码
func currentSetupCode(dataDir string) string {
	b, _ := os.ReadFile(filepath.Join(dataDir, "setup-code"))
	code, exp, ok := strings.Cut(strings.TrimSpace(string(b)), " ")
	t, err := strconv.ParseInt(exp, 10, 64)
	if !ok || err != nil || len(code) != 6 || time.Now().Unix() > t {
		return ""
	}
	return code
}

// Reset C5: 所有设备都丢失时，在服务器上清除同步组；之后用 NewSetupCode 生成注册临时密码。
func Reset(dataDir string) error {
	os.Remove(filepath.Join(dataDir, "latest.json"))
	os.Remove(filepath.Join(dataDir, "setup-code"))
	if err := os.Remove(filepath.Join(dataDir, "verifier")); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// authorized C5: 只允许同步组内的设备收发。
func (s *Server) authorized(r *http.Request) bool {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return false
	}
	s.reloadVerifier()
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
	s.reloadVerifier()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.verifier != "" {
		http.Error(w, "already registered", http.StatusConflict)
		return
	}
	code := currentSetupCode(s.dataDir)
	if code != s.setupCode {
		s.setupCode, s.setupFails = code, 0
	}
	if code == "" || subtle.ConstantTimeCompare([]byte(req.Code), []byte(code)) != 1 {
		s.setupFails++
		if code != "" && s.setupFails >= setupAttempts {
			os.Remove(filepath.Join(s.dataDir, "setup-code"))
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
	s.latest = nil
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
