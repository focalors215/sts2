// Command sts2-frpc runs the official frp client (same library and version as the
// iPad / Android launchers' in-process bridge) for the Windows launcher's online rooms.
//
// Usage: sts2-frpc -c frpc.toml -wait name1,name2
//
// It prints one JSON line per state change to stdout:
//
//	{"state":"running"}                 every proxy in -wait is registered on the server
//	{"state":"error","error":"..."}     login or a proxy failed; the process then exits 1
//
// and keeps the tunnel up until stdin is closed (the launcher exited or stopped the
// room) or the process is killed.
//
// Build: tools/windows/build-frp-helper.sh (GOOS=windows GOARCH=amd64).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/fatedier/frp/client"
	"github.com/fatedier/frp/pkg/config"
	"github.com/fatedier/frp/pkg/config/source"
	"github.com/fatedier/frp/pkg/config/v1/validation"
	"github.com/fatedier/frp/pkg/policy/security"
	"github.com/fatedier/frp/pkg/util/log"
)

func emit(state, message string) {
	out := map[string]string{"state": state}
	if message != "" {
		out["error"] = message
	}
	data, _ := json.Marshal(out)
	fmt.Println(string(data))
}

func newService(path string) (*client.Service, error) {
	result, err := config.LoadClientConfigResult(path, true)
	if err != nil {
		return nil, err
	}
	configSource := source.NewConfigSource()
	if err := configSource.ReplaceAll(result.Proxies, result.Visitors); err != nil {
		return nil, err
	}
	aggregator := source.NewAggregator(configSource)
	proxies, visitors, err := aggregator.Load()
	if err != nil {
		return nil, err
	}
	proxies, visitors = config.FilterClientConfigurers(result.Common, proxies, visitors)
	proxies = config.CompleteProxyConfigurers(proxies)
	visitors = config.CompleteVisitorConfigurers(visitors)
	unsafe := security.NewUnsafeFeatures(nil)
	if _, err := validation.ValidateAllClientConfig(result.Common, proxies, visitors, unsafe); err != nil {
		return nil, err
	}
	log.InitLogger(result.Common.Log.To, result.Common.Log.Level, int(result.Common.Log.MaxDays), true)
	return client.NewService(client.ServiceOptions{
		Common:                 result.Common,
		ConfigSourceAggregator: aggregator,
		UnsafeFeatures:         unsafe,
		ConfigFilePath:         path,
	})
}

func main() {
	configPath := flag.String("c", "", "frpc TOML config file")
	wait := flag.String("wait", "", "comma-separated proxy names that must be running")
	flag.Parse()
	if *configPath == "" {
		emit("error", "missing -c")
		os.Exit(2)
	}
	svr, err := newService(*configPath)
	if err != nil {
		emit("error", err.Error())
		os.Exit(1)
	}
	runErr := make(chan error, 1)
	go func() { runErr <- svr.Run(context.Background()) }()
	go func() {
		// The launcher holds our stdin; EOF means it is gone or wants the room closed.
		_, _ = io.Copy(io.Discard, os.Stdin)
		svr.Close()
		os.Exit(0)
	}()

	var names []string
	for _, name := range strings.Split(*wait, ",") {
		if name = strings.TrimSpace(name); name != "" {
			names = append(names, name)
		}
	}
	ready := false
	ticker := time.NewTicker(300 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case err := <-runErr:
			if err == nil || errors.Is(err, context.Canceled) {
				err = errors.New("frp client stopped")
			}
			emit("error", err.Error())
			os.Exit(1)
		case <-ticker.C:
		}
		running := 0
		for _, name := range names {
			status, ok := svr.StatusExporter().GetProxyStatus(name)
			if !ok {
				continue
			}
			switch status.Phase {
			case "running":
				running++
			case "start error", "check failed", "closed":
				emit("error", fmt.Sprintf("%s: %s", status.Phase, status.Err))
				svr.Close()
				os.Exit(1)
			}
		}
		if running == len(names) && !ready {
			ready = true
			emit("running", "")
		} else if running < len(names) && ready {
			// A reconnect drops proxies back to starting; report it so the UI can show it.
			ready = false
			emit("starting", "")
		}
	}
}
