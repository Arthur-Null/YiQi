package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"

	"qi/sync/relay"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: yiqi-relay init|serve ...")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "init":
		fs := flag.NewFlagSet("init", flag.ExitOnError)
		data := fs.String("data", "/var/lib/yiqi-relay", "")
		url := fs.String("url", "", "wss://<domain>/v1/ws")
		fs.Parse(os.Args[2:])
		code, err := relay.Init(*data, *url)
		if err != nil {
			log.Fatal(err)
		}
		fmt.Println(code)
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
