// C4, C8: 公网中转：每个同步组各自保存最新一条剪贴板密文和每台设备最新的词库快照密文，只转发给本组内的其他在线设备。
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
	"regexp"
	"sort"
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

// group C8: 一个同步组：以认证摘要标识，数据放在 <数据目录>/groups/<摘要>/，与其他组完全隔离。
type group struct {
	id      string
	dir     string
	latest  []byte
	dicts   map[string][]byte
	clients map[*websocket.Conn]chan []byte
	invite  *invite
}

type Server struct {
	dataDir string

	mu         sync.Mutex
	groups     map[string]*group
	setupCode  string
	setupFails int
	joins      map[string]chan string
}

func groupsDir(dataDir string) string { return filepath.Join(dataDir, "groups") }

func New(dataDir string) (*Server, error) {
	if err := os.MkdirAll(groupsDir(dataDir), 0o700); err != nil {
		return nil, err
	}
	migrateSingleGroup(dataDir)
	s := &Server{dataDir: dataDir, groups: map[string]*group{}, joins: map[string]chan string{}}
	s.scanGroups()
	go s.watchGroups()
	return s, nil
}

// migrateSingleGroup C8: 旧版只有一个同步组（数据直接放在数据目录里），升级后原样变成其中一个组。
func migrateSingleGroup(dataDir string) {
	v, err := os.ReadFile(filepath.Join(dataDir, "verifier"))
	if err != nil {
		return
	}
	id := strings.TrimSpace(string(v))
	if !validID.MatchString(id) {
		return
	}
	dir := filepath.Join(groupsDir(dataDir), id)
	if os.MkdirAll(dir, 0o700) != nil {
		return
	}
	os.Rename(filepath.Join(dataDir, "latest.json"), filepath.Join(dir, "latest.json"))
	os.Remove(filepath.Join(dataDir, "verifier"))
}

var validID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

func loadGroup(dir, id string) *group {
	g := &group{id: id, dir: dir, dicts: map[string][]byte{}, clients: map[*websocket.Conn]chan []byte{}}
	g.latest, _ = os.ReadFile(filepath.Join(dir, "latest.json"))
	files, _ := filepath.Glob(filepath.Join(dir, "dict-*.json"))
	for _, f := range files {
		if b, err := os.ReadFile(f); err == nil {
			dev := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(f), "dict-"), ".json")
			g.dicts[dev] = b
		}
	}
	return g
}

// scanGroups C5, C8: 以磁盘上的同步组为准：在服务器上用命令删除某个组后，该组已连接的设备立即断开，无需重启服务。
func (s *Server) scanGroups() {
	entries, _ := os.ReadDir(groupsDir(s.dataDir))
	present := map[string]bool{}
	s.mu.Lock()
	for _, e := range entries {
		if !e.IsDir() || !validID.MatchString(e.Name()) {
			continue
		}
		present[e.Name()] = true
		if s.groups[e.Name()] == nil {
			s.groups[e.Name()] = loadGroup(filepath.Join(groupsDir(s.dataDir), e.Name()), e.Name())
		}
	}
	var gone []*websocket.Conn
	for id, g := range s.groups {
		if present[id] {
			continue
		}
		for c := range g.clients {
			gone = append(gone, c)
		}
		delete(s.groups, id)
	}
	s.mu.Unlock()
	for _, c := range gone {
		c.CloseNow()
	}
}

func (s *Server) watchGroups() {
	for range time.Tick(2 * time.Second) {
		s.scanGroups()
	}
}

// pendingCode C5: 读出仍在有效期内的注册临时密码与它要建的组名
func pendingCode(dataDir string) (code, name string) {
	b, _ := os.ReadFile(filepath.Join(dataDir, "setup-code"))
	fields := strings.SplitN(strings.TrimSpace(string(b)), " ", 3)
	if len(fields) < 2 {
		return "", ""
	}
	t, err := strconv.ParseInt(fields[1], 10, 64)
	if err != nil || len(fields[0]) != 6 || time.Now().Unix() > t {
		return "", ""
	}
	if len(fields) == 3 {
		name = fields[2]
	}
	return fields[0], name
}

// NewSetupCode C5, C8: 在服务器上现场生成注册新同步组用的临时密码，ttl 后失效；name 只用于在服务器上辨认这个组。
func NewSetupCode(dataDir string, ttl time.Duration, name string) (string, error) {
	name = strings.Join(strings.Fields(name), "-")
	code := protocol.NewCode()
	line := code + " " + strconv.FormatInt(time.Now().Add(ttl).Unix(), 10) + " " + name + "\n"
	p := filepath.Join(dataDir, "setup-code")
	if err := os.WriteFile(p, []byte(line), 0o600); err != nil {
		return "", err
	}
	// C5: 命令可能以 root 运行，文件需归服务进程（数据目录的所有者）可读
	chownLike(dataDir, p)
	return code, nil
}

func chownLike(ref, p string) {
	if st, err := os.Stat(ref); err == nil {
		if sys, ok := st.Sys().(*syscall.Stat_t); ok {
			os.Chown(p, int(sys.Uid), int(sys.Gid))
		}
	}
}

// GroupInfo C8: 服务器上一个同步组的概况，供 list 命令显示。
type GroupInfo struct {
	ID      string
	Name    string
	Devices int
	Active  time.Time
}

func Groups(dataDir string) []GroupInfo {
	entries, _ := os.ReadDir(groupsDir(dataDir))
	var out []GroupInfo
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		dir := filepath.Join(groupsDir(dataDir), e.Name())
		gi := GroupInfo{ID: e.Name()}
		if b, err := os.ReadFile(filepath.Join(dir, "name")); err == nil {
			gi.Name = strings.TrimSpace(string(b))
		}
		if st, err := os.Stat(dir); err == nil {
			gi.Active = st.ModTime()
		}
		if st, err := os.Stat(filepath.Join(dir, "latest.json")); err == nil && st.ModTime().After(gi.Active) {
			gi.Active = st.ModTime()
		}
		dicts, _ := filepath.Glob(filepath.Join(dir, "dict-*.json"))
		gi.Devices = len(dicts)
		out = append(out, gi)
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].Name < out[j].Name || (out[i].Name == out[j].Name && out[i].ID < out[j].ID)
	})
	return out
}

var ErrNoGroup = errors.New("no such sync group")

// Reset C5, C8: 在服务器上删除一个同步组（按名称或编号前缀指定），该组的设备全部断开；其他组不受影响。
func Reset(dataDir, which string) error {
	which = strings.TrimSpace(which)
	if which == "" {
		return ErrNoGroup
	}
	var match []GroupInfo
	for _, g := range Groups(dataDir) {
		if g.Name == which || strings.HasPrefix(g.ID, which) {
			match = append(match, g)
		}
	}
	if len(match) != 1 {
		return ErrNoGroup
	}
	return os.RemoveAll(filepath.Join(groupsDir(dataDir), match[0].ID))
}

// authorized C5, C8: 只允许同步组内的设备收发；返回设备所在的组。
func (s *Server) authorized(r *http.Request) *group {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		return nil
	}
	s.scanGroups()
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.groups[protocol.Verifier(token)]
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

// serveClaim C5, C7, C8: 凭服务器生成的临时密码注册一个新的同步组；注册后临时密码作废。
func (s *Server) serveClaim(w http.ResponseWriter, r *http.Request) {
	var req claimRequest
	if r.Method != http.MethodPost || json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&req) != nil ||
		len(req.Verifier) != 43 || !validID.MatchString(req.Verifier) {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	s.scanGroups()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.groups[req.Verifier] != nil {
		http.Error(w, "already registered", http.StatusConflict)
		return
	}
	code, name := pendingCode(s.dataDir)
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
	dir := filepath.Join(groupsDir(s.dataDir), req.Verifier)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		http.Error(w, "storage", http.StatusInternalServerError)
		return
	}
	if name != "" {
		os.WriteFile(filepath.Join(dir, "name"), []byte(name+"\n"), 0o600)
	}
	os.Remove(filepath.Join(s.dataDir, "setup-code"))
	s.groups[req.Verifier] = loadGroup(dir, req.Verifier)
	s.setupCode = ""
	w.WriteHeader(http.StatusOK)
}

// serveJoin C5, C8: 新设备提交一次性公钥，服务器转给正在「添加设备」的设备（可能来自不同的组），
// 取最先给出的答复；只有用对临时密码的新设备才能解开它。
func (s *Server) serveJoin(w http.ResponseWriter, r *http.Request) {
	var f protocol.Frame
	if r.Method != http.MethodPost || json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&f) != nil ||
		f.D == "" {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	reply := make(chan string, len(s.groups)+1)
	var ids []string
	tooMany := false
	for _, g := range s.groups {
		inv := g.invite
		if inv == nil || time.Now().After(inv.expires) {
			g.invite = nil
			continue
		}
		inv.attempts++
		if inv.attempts > inviteAttempts {
			g.invite = nil
			tooMany = true
			continue
		}
		id := randomID()
		s.joins[id] = reply
		ids = append(ids, id)
		msg, _ := json.Marshal(protocol.Frame{T: "join", D: f.D, J: id})
		select {
		case inv.out <- msg:
		default:
		}
	}
	s.mu.Unlock()
	if len(ids) == 0 {
		if tooMany {
			http.Error(w, "too many attempts", http.StatusTooManyRequests)
		} else {
			http.Error(w, "no invite", http.StatusNotFound)
		}
		return
	}
	defer func() {
		s.mu.Lock()
		for _, id := range ids {
			delete(s.joins, id)
		}
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
	g := s.authorized(r)
	if g == nil {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	c, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	c.SetReadLimit(protocol.MaxFrame)
	out := make(chan []byte, 32)
	s.mu.Lock()
	g.clients[c] = out
	var initial [][]byte
	if g.latest != nil {
		initial = append(initial, g.latest)
	}
	for _, d := range g.dicts {
		initial = append(initial, d)
	}
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(g.clients, c)
		if g.invite != nil && g.invite.conn == c {
			g.invite = nil
		}
		s.mu.Unlock()
		c.CloseNow()
	}()

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	write := func(msg []byte) bool {
		wctx, wcancel := context.WithTimeout(ctx, 60*time.Second)
		defer wcancel()
		if c.Write(wctx, websocket.MessageText, msg) != nil {
			cancel()
			return false
		}
		return true
	}
	go func() {
		for _, msg := range initial {
			if !write(msg) {
				return
			}
		}
		t := time.NewTicker(25 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case msg := <-out:
				if !write(msg) {
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

	broadcast := func(data []byte) {
		for other, ch := range g.clients {
			if other == c {
				continue
			}
			select {
			case ch <- data:
			default:
				other.CloseNow()
			}
		}
	}
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
			g.invite = &invite{conn: c, out: out, expires: time.Now().Add(inviteTTL)}
			s.mu.Unlock()
		case "invite-end":
			s.mu.Lock()
			if g.invite != nil && g.invite.conn == c {
				g.invite = nil
			}
			s.mu.Unlock()
		case "join-ok":
			s.mu.Lock()
			if ch, ok := s.joins[f.J]; ok && g.invite != nil && g.invite.conn == c {
				select {
				case ch <- f.D:
				default:
				}
			}
			s.mu.Unlock()
		case "clip":
			s.mu.Lock()
			g.latest = data
			broadcast(data)
			s.mu.Unlock()
			os.WriteFile(filepath.Join(g.dir, "latest.json"), data, 0o600)
		case "dict":
			// C9: 每台设备只保留最新一份词库快照，其他设备上线或收到推送时合并进自己的词库
			if !validID.MatchString(f.F) {
				continue
			}
			s.mu.Lock()
			g.dicts[f.F] = data
			broadcast(data)
			s.mu.Unlock()
			os.WriteFile(filepath.Join(g.dir, "dict-"+f.F+".json"), data, 0o600)
		}
	}
}
