package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"

	"qi/sync/relay"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: yiqi-relay serve|code|reset ...")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "code":
		fs := flag.NewFlagSet("code", flag.ExitOnError)
		data := fs.String("data", "/var/lib/yiqi-relay", "")
		fs.Parse(os.Args[2:])
		code, err := relay.NewSetupCode(*data, relay.SetupCodeTTL)
		if errors.Is(err, relay.ErrRegistered) {
			fmt.Println("同步组已经注册。要加入新设备，请在已同步的设备上点「添加设备」；要重新注册，先运行 yiqi-relay reset。")
			os.Exit(1)
		}
		if err != nil {
			log.Fatal(err)
		}
		fmt.Printf("注册临时密码：%s（%d 分钟内有效，只能用一次）\n", code, int(relay.SetupCodeTTL.Minutes()))
	case "reset":
		fs := flag.NewFlagSet("reset", flag.ExitOnError)
		data := fs.String("data", "/var/lib/yiqi-relay", "")
		fs.Parse(os.Args[2:])
		if err := relay.Reset(*data); err != nil {
			log.Fatal(err)
		}
		fmt.Println("已清除同步组，所有设备已断开。运行 yiqi-relay code 生成注册用的临时密码。")
	case "serve":
		fs := flag.NewFlagSet("serve", flag.ExitOnError)
		data := fs.String("data", "/var/lib/yiqi-relay", "")
		// C4, C7: 监听地址由部署者指定，公网域名与 TLS 由部署者自己的隧道或反向代理提供
		listen := fs.String("listen", "127.0.0.1:40566", "")
		fs.Parse(os.Args[2:])
		s, err := relay.New(*data)
		if err != nil {
			log.Fatal(err)
		}
		log.Fatal(http.ListenAndServe(*listen, s.Handler()))
	}
}
