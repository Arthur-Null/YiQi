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
		fmt.Fprintln(os.Stderr, "usage: yiqi-relay serve|code|list|reset ...")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "code":
		fs := flag.NewFlagSet("code", flag.ExitOnError)
		data := fs.String("data", "/var/lib/yiqi-relay", "")
		name := fs.String("name", "", "")
		fs.Parse(os.Args[2:])
		code, err := relay.NewSetupCode(*data, relay.SetupCodeTTL, *name)
		if err != nil {
			log.Fatal(err)
		}
		fmt.Printf("注册新同步组的临时密码：%s（%d 分钟内有效，只能用一次）\n", code, int(relay.SetupCodeTTL.Minutes()))
	case "list":
		fs := flag.NewFlagSet("list", flag.ExitOnError)
		data := fs.String("data", "/var/lib/yiqi-relay", "")
		fs.Parse(os.Args[2:])
		gs := relay.Groups(*data)
		if len(gs) == 0 {
			fmt.Println("还没有同步组。运行 yiqi-relay code 生成注册临时密码。")
		}
		for _, g := range gs {
			name := g.Name
			if name == "" {
				name = "（未命名）"
			}
			fmt.Printf("%s  编号 %s  词库设备 %d 台  最近活动 %s\n", name, g.ID[:8], g.Devices, g.Active.Format("2006-01-02 15:04"))
		}
	case "reset":
		fs := flag.NewFlagSet("reset", flag.ExitOnError)
		data := fs.String("data", "/var/lib/yiqi-relay", "")
		fs.Parse(os.Args[2:])
		if fs.NArg() != 1 {
			fmt.Fprintln(os.Stderr, "用法：yiqi-relay reset [--data 目录] <组名或编号>（先用 yiqi-relay list 查看）")
			os.Exit(2)
		}
		if err := relay.Reset(*data, fs.Arg(0)); errors.Is(err, relay.ErrNoGroup) {
			fmt.Println("没有找到这个同步组，或编号前缀对应了多个组。先运行 yiqi-relay list 查看。")
			os.Exit(1)
		} else if err != nil {
			log.Fatal(err)
		}
		fmt.Println("已删除该同步组，它的设备已断开，其他同步组不受影响。")
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
