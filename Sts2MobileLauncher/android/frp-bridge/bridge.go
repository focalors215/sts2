// Package main exposes the official frp client as a small C API so the mobile
// launchers can run it in-process (same API as sts2-ios/src/FrpBridge).
//
// Build: tools/android/build-frp-bridge.sh (c-shared for android/arm64; JNI in jni_android.c).
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/fatedier/frp/client"
	"github.com/fatedier/frp/pkg/config"
	"github.com/fatedier/frp/pkg/config/source"
	"github.com/fatedier/frp/pkg/config/v1/validation"
	"github.com/fatedier/frp/pkg/policy/security"
	"github.com/fatedier/frp/pkg/util/log"
)

type bridge struct {
	mu      sync.Mutex
	svr     *client.Service
	running bool
	runErr  string
}

var state bridge

func start(path string) error {
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.running {
		return errors.New("frp 已在运行")
	}
	result, err := config.LoadClientConfigResult(path, true)
	if err != nil {
		return err
	}
	configSource := source.NewConfigSource()
	if err := configSource.ReplaceAll(result.Proxies, result.Visitors); err != nil {
		return err
	}
	aggregator := source.NewAggregator(configSource)
	proxies, visitors, err := aggregator.Load()
	if err != nil {
		return err
	}
	proxies, visitors = config.FilterClientConfigurers(result.Common, proxies, visitors)
	proxies = config.CompleteProxyConfigurers(proxies)
	visitors = config.CompleteVisitorConfigurers(visitors)
	unsafe := security.NewUnsafeFeatures(nil)
	if _, err := validation.ValidateAllClientConfig(result.Common, proxies, visitors, unsafe); err != nil {
		return err
	}
	log.InitLogger(result.Common.Log.To, result.Common.Log.Level, int(result.Common.Log.MaxDays), true)
	svr, err := client.NewService(client.ServiceOptions{
		Common:                 result.Common,
		ConfigSourceAggregator: aggregator,
		UnsafeFeatures:         unsafe,
		ConfigFilePath:         path,
	})
	if err != nil {
		return err
	}
	state.svr, state.running, state.runErr = svr, true, ""
	go func() {
		err := svr.Run(context.Background())
		state.mu.Lock()
		defer state.mu.Unlock()
		if state.svr == svr {
			state.running = false
			if err != nil && !errors.Is(err, context.Canceled) {
				state.runErr = err.Error()
			}
		}
	}()
	return nil
}

// Sts2FrpStart loads a frpc TOML config file and starts the client in the
// background. Returns NULL on success, otherwise an error message the caller
// must free().
//
//export Sts2FrpStart
func Sts2FrpStart(path *C.char) *C.char {
	if err := start(C.GoString(path)); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

// Sts2FrpStatus returns JSON {"state","error","remoteAddr"} for a proxy;
// state is one of starting, running, error, stopped. Caller must free().
//
//export Sts2FrpStatus
func Sts2FrpStatus(proxyName *C.char) *C.char {
	name := C.GoString(proxyName)
	out := map[string]string{"state": "stopped"}
	state.mu.Lock()
	switch {
	case state.runErr != "":
		out["state"], out["error"] = "error", state.runErr
	case state.running && state.svr != nil:
		out["state"] = "starting"
		if ws, ok := state.svr.StatusExporter().GetProxyStatus(name); ok {
			switch ws.Phase {
			case "running":
				out["state"], out["remoteAddr"] = "running", ws.RemoteAddr
			case "start error", "check failed", "closed":
				out["state"], out["error"] = "error", fmt.Sprintf("%s: %s", ws.Phase, ws.Err)
			}
		}
	}
	state.mu.Unlock()
	data, _ := json.Marshal(out)
	return C.CString(string(data))
}

// Sts2FrpStop closes the client. Safe to call when not running.
//
//export Sts2FrpStop
func Sts2FrpStop() {
	state.mu.Lock()
	svr := state.svr
	state.svr, state.running, state.runErr = nil, false, ""
	state.mu.Unlock()
	if svr != nil {
		svr.Close()
	}
}

// Room discovery. Each host publishes a small JSON "room card" on a loopback TCP
// listener, exposed through frp next to its game UDP port. Clients find rooms by
// probing the fixed slot ports on the server; no extra server software is needed.

var room struct {
	mu       sync.Mutex
	listener net.Listener
	info     []byte
}

// Sts2RoomServe serves info (JSON) to every TCP connection on 127.0.0.1 and
// returns the local port, or -1 on failure. Replaces the card if already serving.
//
//export Sts2RoomServe
func Sts2RoomServe(info *C.char) C.int {
	room.mu.Lock()
	defer room.mu.Unlock()
	room.info = []byte(C.GoString(info))
	if room.listener == nil {
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return -1
		}
		room.listener = l
		go func() {
			for {
				conn, err := l.Accept()
				if err != nil {
					return
				}
				room.mu.Lock()
				data := room.info
				room.mu.Unlock()
				go func() {
					defer conn.Close()
					_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
					_, _ = conn.Write(data)
				}()
			}
		}()
	}
	return C.int(room.listener.Addr().(*net.TCPAddr).Port)
}

// Sts2RoomStopServe closes the room card listener.
//
//export Sts2RoomStopServe
func Sts2RoomStopServe() {
	room.mu.Lock()
	defer room.mu.Unlock()
	if room.listener != nil {
		_ = room.listener.Close()
		room.listener = nil
	}
}

// Sts2RoomScan probes count TCP ports starting at firstPort on server in parallel
// and returns a JSON array of {"slot", "info"} for ports that answered with a
// JSON object. Caller must free().
//
//export Sts2RoomScan
func Sts2RoomScan(server *C.char, firstPort, count, timeoutMs C.int) *C.char {
	host := C.GoString(server)
	timeout := time.Duration(timeoutMs) * time.Millisecond
	type found struct {
		Slot int             `json:"slot"`
		Info json.RawMessage `json:"info"`
	}
	results := make([]*found, int(count))
	var wg sync.WaitGroup
	for i := 0; i < int(count); i++ {
		wg.Add(1)
		go func(slot int) {
			defer wg.Done()
			addr := net.JoinHostPort(host, strconv.Itoa(int(firstPort)+slot))
			conn, err := net.DialTimeout("tcp", addr, timeout)
			if err != nil {
				return
			}
			defer conn.Close()
			_ = conn.SetReadDeadline(time.Now().Add(timeout))
			data, _ := io.ReadAll(io.LimitReader(conn, 8192))
			var probe map[string]any
			if json.Unmarshal(data, &probe) == nil {
				results[slot] = &found{Slot: slot, Info: data}
			}
		}(i)
	}
	wg.Wait()
	list := make([]*found, 0, len(results))
	for _, r := range results {
		if r != nil {
			list = append(list, r)
		}
	}
	data, _ := json.Marshal(list)
	return C.CString(string(data))
}

func main() {}
