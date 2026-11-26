//go:build linux

package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"
	"time"
)

// LinuxClipboard C3: 兼容 Wayland（wl-paste/wl-copy）与 X11（xclip/xsel）的剪贴板读写，支持几千字长文本。
type LinuxClipboard struct{}

func isWayland() bool {
	return os.Getenv("WAYLAND_DISPLAY") != ""
}

func runRead(name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		return "", err
	}
	return out.String(), nil
}

func runWrite(text, name string, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = strings.NewReader(text)
	return cmd.Start()
}

func (LinuxClipboard) Read() (string, error) {
	if isWayland() {
		if _, err := exec.LookPath("wl-paste"); err == nil {
			s, err := runRead("wl-paste", "--no-newline", "--type", "text/plain;charset=utf-8")
			if err == nil {
				return s, nil
			}
			return runRead("wl-paste", "--no-newline")
		}
	}
	if _, err := exec.LookPath("xclip"); err == nil {
		return runRead("xclip", "-selection", "clipboard", "-out")
	}
	if _, err := exec.LookPath("xsel"); err == nil {
		return runRead("xsel", "--clipboard", "--output")
	}
	return "", errors.New("no clipboard tool found")
}

func (LinuxClipboard) Write(text string) error {
	if isWayland() {
		if _, err := exec.LookPath("wl-copy"); err == nil {
			return runWrite(text, "wl-copy", "--type", "text/plain;charset=utf-8")
		}
	}
	if _, err := exec.LookPath("xclip"); err == nil {
		return runWrite(text, "xclip", "-selection", "clipboard", "-in")
	}
	if _, err := exec.LookPath("xsel"); err == nil {
		return runWrite(text, "xsel", "--clipboard", "--input")
	}
	return errors.New("no clipboard tool found")
}
