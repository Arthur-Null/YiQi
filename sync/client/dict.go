package client

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"time"

	"github.com/coder/websocket"

	"qi/sync/protocol"
)

// DictFile C9: Rime 为用户词库（打字学到的词与词频）导出的文本快照；全拼与小鹤双拼共用同一份词库。
const DictFile = "rime_frost.userdb.txt"

// DictSync C9: 用户词库跨设备同步。借用 Rime 自带的「同步用户资料」：本机导出快照到 <用户目录>/sync/<本机安装号>/，
// 其他设备的快照放进 <用户目录>/sync/<设备号>/，Rime 同步时把它们合并进本机词库。
// 本类型负责快照的加密收发；让 Rime 执行同步由各平台提供 Trigger。
type DictSync struct {
	// Dirs 是 Rime 用户目录（Linux 上 Fcitx5 与 IBus 可能各有一个）。
	Dirs []string
	// Trigger 请 Rime 执行一次同步（导出本机快照并合并其他设备的快照）；为空时只收发快照文件，由用户在输入法菜单里手动同步。
	Trigger func() error
}

var installationID = regexp.MustCompile(`(?m)^installation_id:\s*"?([^"\s]+)"?`)

func (d *DictSync) ownSnapshot(dir string) string {
	b, err := os.ReadFile(filepath.Join(dir, "installation.yaml"))
	if err != nil {
		return ""
	}
	m := installationID.FindSubmatch(b)
	if m == nil {
		return ""
	}
	return filepath.Join(dir, "sync", string(m[1]), DictFile)
}

// readOwn 返回本机最新的词库快照（多个用户目录取修改时间最新的）及其修改时间。
func (d *DictSync) readOwn() ([]byte, time.Time) {
	var best []byte
	var bestT time.Time
	for _, dir := range d.Dirs {
		p := d.ownSnapshot(dir)
		if p == "" {
			continue
		}
		st, err := os.Stat(p)
		if err != nil {
			continue
		}
		if b, err := os.ReadFile(p); err == nil && (best == nil || st.ModTime().After(bestT)) {
			best, bestT = b, st.ModTime()
		}
	}
	return best, bestT
}

// fingerprint 只看词条，不看文件头（版本、tick 等），避免只因合并导致头部变化而反复上传。
func fingerprint(text []byte) [32]byte {
	var body bytes.Buffer
	for _, line := range bytes.Split(text, []byte("\n")) {
		if !bytes.HasPrefix(line, []byte("#")) {
			body.Write(line)
			body.WriteByte('\n')
		}
	}
	return sha256.Sum256(body.Bytes())
}

var validDevice = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

// store 把其他设备的快照放进每个用户目录的同步文件夹；返回内容是否有变化。
func (d *DictSync) store(from string, text []byte) bool {
	if !validDevice.MatchString(from) {
		return false
	}
	changed := false
	for _, dir := range d.Dirs {
		p := filepath.Join(dir, "sync", from, DictFile)
		if old, err := os.ReadFile(p); err == nil && bytes.Equal(old, text) {
			continue
		}
		if writeAtomic(p, text) == nil {
			changed = true
		}
	}
	return changed
}

var (
	dictFirst    = 5 * time.Second
	dictPeriod   = 30 * time.Minute
	dictDebounce = 20 * time.Second
	dictWait     = 40 * time.Second
)

// kickDict 通知词库同步循环：有其他设备的新快照需要合并。
func (s *Syncer) kickDict() {
	select {
	case s.dictKick <- struct{}{}:
	default:
	}
}

func (s *Syncer) applyDict(k protocol.Key, f protocol.Frame) {
	if s.Dict == nil || f.F == "" || f.F == s.DeviceID {
		return
	}
	text, err := k.OpenDict(f)
	if err != nil {
		return
	}
	if s.Dict.store(f.F, text) {
		s.kickDict()
	}
}

// dictLoop C9: 连上服务器后：先同步一次，之后每次收到其他设备的新快照（稍作合并等待）或每隔半小时同步一次，
// 并把本机快照在内容变化时发给其他设备。
func (s *Syncer) dictLoop(ctx context.Context, conn *websocket.Conn, k protocol.Key) {
	d := s.Dict
	if d == nil {
		return
	}
	var sent [32]byte
	tick := time.NewTicker(dictPeriod)
	defer tick.Stop()
	first := time.After(dictFirst)
	for {
		select {
		case <-ctx.Done():
			return
		case <-first:
			first = nil
		case <-tick.C:
		case <-s.dictKick:
			select {
			case <-ctx.Done():
				return
			case <-time.After(dictDebounce):
			}
		}
		_, before := d.readOwn()
		if d.Trigger != nil {
			if d.Trigger() == nil {
				deadline := time.Now().Add(dictWait)
				for time.Now().Before(deadline) {
					if _, t := d.readOwn(); t.After(before) {
						break
					}
					select {
					case <-ctx.Done():
						return
					case <-time.After(time.Second):
					}
				}
			}
		}
		text, _ := d.readOwn()
		if text == nil || len(text) == 0 {
			continue
		}
		if fp := fingerprint(text); fp != sent {
			f, err := k.SealDict(s.DeviceID, text)
			if err != nil {
				continue
			}
			b, _ := json.Marshal(f)
			wctx, cancel := context.WithTimeout(ctx, 60*time.Second)
			err = conn.Write(wctx, websocket.MessageText, b)
			cancel()
			if err != nil {
				return
			}
			sent = fp
		}
	}
}
