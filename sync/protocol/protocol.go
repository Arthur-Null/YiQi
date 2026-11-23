// C5: 内容在设备上用配对密钥加密，服务器只见密文；只有持有配对密钥的设备能通过认证。
package protocol

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
)

// MaxText C3: 单网页级别（几千字）的长文本需完整同步，上限留足余量。
const MaxText = 1 << 20

// MaxFrame C3: 密文帧上限（含加密与编码开销）。
const MaxFrame = 4 << 20

type Key [32]byte

func NewKey() (Key, error) {
	var k Key
	_, err := rand.Read(k[:])
	return k, err
}

func derive(k Key, label string) []byte {
	m := hmac.New(sha256.New, k[:])
	m.Write([]byte(label))
	return m.Sum(nil)
}

// AuthToken C5: 设备向服务器证明自己持有配对密钥。
func (k Key) AuthToken() string {
	return base64.RawURLEncoding.EncodeToString(derive(k, "qi-auth-v1"))
}

// Verifier C5: 服务器只保存认证令牌的摘要。
func Verifier(token string) string {
	sum := sha256.Sum256([]byte(token))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func (k Key) aead() cipher.AEAD {
	block, _ := aes.NewCipher(derive(k, "qi-enc-v1"))
	g, _ := cipher.NewGCM(block)
	return g
}

type Clip struct {
	ID   string `json:"id"`
	From string `json:"from"`
	TS   int64  `json:"ts"`
	Text string `json:"text"`
}

type Frame struct {
	T string `json:"t"`
	D string `json:"d,omitempty"`
	J string `json:"j,omitempty"`
}

func (k Key) Seal(c Clip) (Frame, error) {
	if len(c.Text) > MaxText {
		return Frame{}, fmt.Errorf("text too long: %d", len(c.Text))
	}
	plain, err := json.Marshal(c)
	if err != nil {
		return Frame{}, err
	}
	a := k.aead()
	nonce := make([]byte, a.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return Frame{}, err
	}
	sealed := a.Seal(nonce, nonce, plain, nil)
	return Frame{T: "clip", D: base64.StdEncoding.EncodeToString(sealed)}, nil
}

func (k Key) Open(f Frame) (Clip, error) {
	var c Clip
	raw, err := base64.StdEncoding.DecodeString(f.D)
	if err != nil {
		return c, err
	}
	a := k.aead()
	if len(raw) < a.NonceSize() {
		return c, errors.New("short frame")
	}
	plain, err := a.Open(nil, raw[:a.NonceSize()], raw[a.NonceSize():], nil)
	if err != nil {
		return c, err
	}
	err = json.Unmarshal(plain, &c)
	return c, err
}

// PairCode C5: 配对码只在用户自己的设备之间传递，含服务器地址与配对密钥。
func PairCode(server string, k Key) string {
	return "qi://pair?s=" + url.QueryEscape(server) + "&k=" + base64.RawURLEncoding.EncodeToString(k[:])
}

func ParsePairCode(code string) (string, Key, error) {
	var k Key
	u, err := url.Parse(strings.TrimSpace(code))
	if err != nil || u.Scheme != "qi" || u.Host != "pair" {
		return "", k, errors.New("not a qi pair code")
	}
	server := u.Query().Get("s")
	raw, err := base64.RawURLEncoding.DecodeString(u.Query().Get("k"))
	if err != nil || len(raw) != len(k) || server == "" {
		return "", k, errors.New("bad pair code")
	}
	copy(k[:], raw)
	return server, k, nil
}
