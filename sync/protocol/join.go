package protocol

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"math/big"
	"strings"
)

// C5: 新设备加入同步组。两台设备各生成一次性的 P-256 密钥交换，6 位临时密码参与派生加密密钥，
// 同步组密钥只在两台设备之间传递；服务器和中间网络只转发公钥与密文，旁听拿不到密钥。

func NewCode() string {
	n, _ := rand.Int(rand.Reader, big.NewInt(1000000))
	return fmt.Sprintf("%06d", n.Int64())
}

func NewEphemeral() (*ecdh.PrivateKey, error) {
	return ecdh.P256().GenerateKey(rand.Reader)
}

func joinAEAD(priv *ecdh.PrivateKey, peer []byte, code string) (cipher.AEAD, error) {
	pub, err := ecdh.P256().NewPublicKey(peer)
	if err != nil {
		return nil, err
	}
	shared, err := priv.ECDH(pub)
	if err != nil {
		return nil, err
	}
	m := hmac.New(sha256.New, shared)
	m.Write([]byte("yiqi-join-v1|" + code))
	block, _ := aes.NewCipher(m.Sum(nil))
	return cipher.NewGCM(block)
}

// SealGroupKey C5: 由已同步的设备调用，返回 "<本机公钥>.<密文>"。
func SealGroupKey(peer []byte, code string, k Key) (string, error) {
	priv, err := NewEphemeral()
	if err != nil {
		return "", err
	}
	a, err := joinAEAD(priv, peer, code)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, a.NonceSize())
	rand.Read(nonce)
	sealed := a.Seal(nonce, nonce, k[:], nil)
	return base64.StdEncoding.EncodeToString(priv.PublicKey().Bytes()) + "." + base64.StdEncoding.EncodeToString(sealed), nil
}

// OpenGroupKey C5: 由新设备调用；临时密码不对时解密失败。
func OpenGroupKey(priv *ecdh.PrivateKey, reply, code string) (Key, error) {
	var k Key
	pa, e, ok := strings.Cut(reply, ".")
	if !ok {
		return k, errors.New("bad reply")
	}
	peer, err1 := base64.StdEncoding.DecodeString(pa)
	raw, err2 := base64.StdEncoding.DecodeString(e)
	if err1 != nil || err2 != nil {
		return k, errors.New("bad reply")
	}
	a, err := joinAEAD(priv, peer, code)
	if err != nil {
		return k, err
	}
	if len(raw) < a.NonceSize() {
		return k, errors.New("bad reply")
	}
	plain, err := a.Open(nil, raw[:a.NonceSize()], raw[a.NonceSize():], nil)
	if err != nil || len(plain) != len(k) {
		return k, errors.New("wrong code")
	}
	copy(k[:], plain)
	return k, nil
}
