// gnoracle-bot announces protocol events and deadlines and cranks the
// permissionless entry points.
//
//	gnoracle-bot -config bot.toml
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/clockworkgr/gnoracle/bot"
	"github.com/clockworkgr/gnoracle/internal/gnochain"
)

func main() {
	cfgPath := flag.String("config", "bot.toml", "configuration file")
	once := flag.Bool("once", false, "run one tick and exit")
	flag.Parse()

	cfg, err := bot.Load(*cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
		os.Exit(2)
	}
	client, err := gnochain.New(gnochain.Config{Remote: cfg.Remote, ChainID: cfg.ChainID, KeyHome: cfg.KeyHome, KeyName: cfg.Key, PasswordFile: cfg.PasswordFile, Gas: cfg.Gas})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	b, err := bot.New(cfg, client)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if *once {
		b.Tick(ctx)
		return
	}
	if err := b.Run(ctx); err != nil {
		log.Fatal(err)
	}
}
