// gnoracle-agent serves oracle feeds as a registered provider.
//
//	gnoracle-agent -config agent.toml
//	gnoracle-agent -config agent.toml -once   # one pass, then exit
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/clockworkgr/gnoracle/agent"
	"github.com/clockworkgr/gnoracle/internal/gnochain"
)

func main() {
	cfgPath := flag.String("config", "agent.toml", "configuration file")
	once := flag.Bool("once", false, "run one tick per feed and exit")
	check := flag.Bool("check", false, "validate the configuration and the key, then exit")
	flag.Parse()

	cfg, err := agent.Load(*cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
		os.Exit(2)
	}
	client, err := gnochain.New(gnochain.Config{Remote: cfg.Remote, ChainID: cfg.ChainID, KeyHome: cfg.KeyHome, KeyName: cfg.Key, PasswordFile: cfg.PasswordFile, Gas: cfg.Gas})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if *check {
		bal, err := client.Balance(client.Address())
		if err != nil {
			fmt.Fprintln(os.Stderr, "balance:", err)
			os.Exit(1)
		}
		fmt.Printf("ok: %s on %s (%s), balance %d ugnot, %d feed(s)\n", client.Bech32(), cfg.Remote, cfg.ChainID, bal, len(cfg.Feeds))
		return
	}
	a, err := agent.New(cfg, client)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if *once {
		if err := a.Once(ctx); err != nil {
			log.Fatal(err)
		}
		return
	}
	if err := a.Run(ctx); err != nil {
		log.Fatal(err)
	}
}
