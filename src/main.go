// ALKO Proxy Standalone: local utility control panel and optional native GTProxy bridge.
// This executable is not itself an ENet Growtopia proxy, and cannot claim v5.61 compatibility.
package main

import (
	"bufio"
	"crypto/rand"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed web/index.html web/style.css web/app.js
var assets embed.FS

var allowed = map[string]bool{"alko": true, "help": true, "proxy": true, "warp": true, "nick": true, "skin": true, "debug": true, "exit": true, "gscan": true, "counts": true, "pos": true, "people": true, "dropped": true, "farmreport": true, "qdrop": true, "qtrash": true, "ping": true}
var tokenScrub = regexp.MustCompile(`(?i)(token|password|session|oauth|wk|rid|mac)\s*[:=|]\s*\S+`)
var worldName = regexp.MustCompile(`^[A-Za-z0-9_]{1,24}$`)

func randomID() string {
	b := make([]byte, 16)
	_, err := rand.Read(b)
	if err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
func validateCommand(s string) (string, error) {
	s = strings.TrimSpace(s)
	if len(s) > 180 || len(s) < 2 || s[0] != '/' {
		return "", errors.New("Use a single /command (max 180 ASCII characters)")
	}
	for _, r := range s {
		if r < 32 || r > 126 {
			return "", errors.New("Only printable ASCII commands are accepted")
		}
	}
	p := strings.Fields(s)
	cmd := strings.ToLower(strings.TrimPrefix(p[0], "/"))
	if !allowed[cmd] {
		return "", fmt.Errorf("Unsupported command /%s", cmd)
	}
	if cmd == "warp" && (len(p) != 2 || !worldName.MatchString(p[1])) {
		return "", errors.New("Warp expects /warp WORLDNAME")
	}
	if cmd == "qdrop" || cmd == "qtrash" {
		if len(p) != 3 {
			return "", errors.New("Usage: /qdrop ITEM_ID AMOUNT or /qtrash ITEM_ID AMOUNT")
		}
		id, e1 := strconv.Atoi(p[1])
		count, e2 := strconv.Atoi(p[2])
		if e1 != nil || e2 != nil || id <= 0 || id >= 1000000 || count < 1 || count > 200 {
			return "", errors.New("Item ID must be positive; amount 1–200")
		}
	}
	return s, nil
}

type logItem struct {
	Time    string `json:"time"`
	Message string `json:"message"`
}
type receipt map[string]any
type WFState struct {
	Running   bool `json:"running"`
	Name      any  `json:"name"`
	Completed int  `json:"completed"`
	Total     int  `json:"total"`
	Error     any  `json:"error"`
}
type Step struct {
	Command string `json:"command,omitempty"`
	WaitMS  int    `json:"wait_ms,omitempty"`
}
type Controller struct {
	mu         sync.Mutex
	token      string
	runtimeDir string
	bridgeDir  string
	settings   map[string]any
	logs       []logItem
	started    time.Time
	cmd        *exec.Cmd
	session    string
	wf         WFState
	wfStop     chan struct{}
	wfActive   bool
}

func defaultSettings() map[string]any {
	return map[string]any{"engine_path": "", "target_version": "5.61", "allow_lua": false, "confirm_trash": true, "world_label": "", "saved_worlds": []any{"START"}, "dark_mode": true}
}
func newController(dir string) (*Controller, error) {
	c := &Controller{token: randomID(), runtimeDir: dir, bridgeDir: filepath.Join(dir, "bridge"), settings: defaultSettings(), started: time.Now(), wf: WFState{Running: false, Name: nil, Error: nil}}
	for _, d := range []string{"inbox", "outbox", "telemetry"} {
		if err := os.MkdirAll(filepath.Join(c.bridgeDir, d), 0700); err != nil {
			return nil, err
		}
	}
	if b, err := os.ReadFile(filepath.Join(dir, "settings.json")); err == nil {
		var m map[string]any
		if json.Unmarshal(b, &m) == nil {
			for k := range c.settings {
				if v, ok := m[k]; ok {
					c.settings[k] = v
				}
			}
		}
	}
	c.log("ALKO standalone dashboard started — native game engine not included")
	return c, nil
}
func (c *Controller) log(s string) { c.mu.Lock(); defer c.mu.Unlock(); c.logUnsafe(s) }
func (c *Controller) logUnsafe(s string) {
	s = tokenScrub.ReplaceAllString(s, "$1=[REDACTED]")
	if len(s) > 400 {
		s = s[:400]
	}
	c.logs = append(c.logs, logItem{Time: time.Now().Format("15:04:05"), Message: s})
	if len(c.logs) > 450 {
		c.logs = c.logs[len(c.logs)-450:]
	}
}

type heartbeat struct {
	Bridge     string `json:"bridge"`
	Engine     string `json:"engine"`
	Session    string `json:"session"`
	Connection string `json:"connection"`
	Bootstrap  string `json:"bootstrap"`
}

func (c *Controller) readHeartbeat(session string) (heartbeat, bool) {
	f, err := os.Open(filepath.Join(c.bridgeDir, "telemetry", "heartbeat.json"))
	if err != nil {
		return heartbeat{}, false
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return heartbeat{}, false
	}
	age := time.Since(fi.ModTime())
	var h heartbeat
	if age < 0 || age >= 5*time.Second || json.NewDecoder(io.LimitReader(f, 4096)).Decode(&h) != nil ||
		h.Bridge != "online" || h.Engine != "GTProxy" || h.Session != session {
		return heartbeat{}, false
	}
	return h, true
}
func (c *Controller) status() map[string]any {
	c.mu.Lock()
	run := c.cmd != nil
	pid := any(nil)
	if run && c.cmd.Process != nil {
		pid = c.cmd.Process.Pid
	}
	wf, session := c.wf, c.session
	c.mu.Unlock()
	queued := 0
	files, _ := os.ReadDir(filepath.Join(c.bridgeDir, "inbox", session))
	for _, f := range files {
		if strings.HasSuffix(f.Name(), ".cmd") || strings.HasSuffix(f.Name(), ".lua") {
			queued++
		}
	}
	r := c.receipts(8)
	engine := "stopped"
	if run {
		engine = "running"
	}
	bridge, connection, bootstrap := "offline", "unknown", "unknown"
	if !run {
		connection = "disconnected"
	} else if h, ok := c.readHeartbeat(session); ok {
		bridge, connection, bootstrap = "online", h.Connection, h.Bootstrap
	}
	return map[string]any{"dashboard": "online", "engine": engine, "bridge": bridge, "connection": connection, "bootstrap": bootstrap, "target_version": "5.61", "compatibility": "UNVERIFIED — requires successful live test", "uptime_seconds": int(time.Since(c.started).Seconds()), "pid": pid, "workflow": wf, "queued": queued, "recent_receipts": r}
}
func (c *Controller) receipts(n int) []receipt {
	dir := filepath.Join(c.bridgeDir, "outbox")
	entries, _ := os.ReadDir(dir)
	type entry struct {
		name string
		time time.Time
	}
	all := []entry{}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".json") {
			if fi, err := e.Info(); err == nil {
				all = append(all, entry{e.Name(), fi.ModTime()})
			}
		}
	}
	sort.Slice(all, func(i, j int) bool { return all[i].time.After(all[j].time) })
	out := []receipt{}
	for i, e := range all {
		if i >= n {
			break
		}
		b, err := os.ReadFile(filepath.Join(dir, e.name))
		if err == nil {
			m := receipt{}
			if json.Unmarshal(b, &m) == nil {
				out = append(out, m)
			}
		}
	}
	return out
}
func copySettings(m map[string]any) map[string]any {
	out := map[string]any{}
	for k, v := range m {
		out[k] = v
	}
	return out
}
func (c *Controller) saveSettings(p map[string]any) (map[string]any, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	next := copySettings(c.settings)
	for k, v := range p {
		if _, ok := next[k]; !ok {
			continue
		}
		switch k {
		case "engine_path":
			s, ok := v.(string)
			if !ok || len(s) > 1024 {
				return nil, errors.New("Invalid engine path")
			}
			next[k] = strings.TrimSpace(s)
		case "target_version":
			if v != "5.61" {
				return nil, errors.New("This build targets 5.61; future versions require review")
			}
		case "confirm_trash", "allow_lua", "dark_mode":
			b, ok := v.(bool)
			if !ok {
				return nil, fmt.Errorf("%s must be boolean", k)
			}
			next[k] = b
		case "world_label":
			s, ok := v.(string)
			if !ok {
				return nil, errors.New("Invalid world label")
			}
			if len(s) > 64 {
				s = s[:64]
			}
			next[k] = s
		case "saved_worlds":
			a, ok := v.([]any)
			if !ok || len(a) > 24 {
				return nil, errors.New("saved_worlds must be list of at most 24")
			}
			out := []any{}
			for _, x := range a {
				s, ok := x.(string)
				if ok && worldName.MatchString(s) {
					out = append(out, strings.ToUpper(s))
				}
			}
			next[k] = out
		}
	}
	b, _ := json.MarshalIndent(next, "", "  ")
	if err := os.WriteFile(filepath.Join(c.runtimeDir, "settings.json"), b, 0600); err != nil {
		return nil, err
	}
	c.settings = next
	return copySettings(next), nil
}
func (c *Controller) engineStart() (map[string]any, error) {
	c.mu.Lock()
	err := c.launchEngine()
	c.mu.Unlock()
	if err != nil {
		return nil, err
	}
	return c.status(), nil
}

func (c *Controller) launchEngine() error {
	if c.cmd != nil {
		return errors.New("Engine is already running")
	}
	path, _ := c.settings["engine_path"].(string)
	if path == "" {
		return errors.New("The native GTProxy engine is not included. Set its compiled executable path in Settings first.")
	}
	abs, err := filepath.Abs(os.ExpandEnv(path))
	if err != nil {
		return err
	}
	fi, err := os.Stat(abs)
	if err != nil || fi.IsDir() {
		return errors.New("Engine executable not found")
	}
	if runtime.GOOS == "windows" && !strings.EqualFold(filepath.Ext(abs), ".exe") {
		return errors.New("Expected a Windows .exe engine")
	}
	session := randomID()
	inbox := filepath.Join(c.bridgeDir, "inbox", session)
	if err := os.Mkdir(inbox, 0700); err != nil {
		return err
	}
	cmd := exec.Command(abs)
	cmd.Dir = filepath.Dir(abs)
	cmd.Env = append(os.Environ(), "ALKO_BRIDGE_DIR="+c.bridgeDir, "ALKO_BRIDGE_SESSION="+session)
	rd, err := cmd.StdoutPipe()
	if err != nil {
		_ = os.Remove(inbox)
		return err
	}
	cmd.Stderr = cmd.Stdout
	if err = cmd.Start(); err != nil {
		_ = rd.Close()
		_ = os.Remove(inbox)
		return err
	}
	c.cmd, c.session = cmd, session
	c.logUnsafe(fmt.Sprintf("Engine PID %d launched from %s", cmd.Process.Pid, cmd.Dir))
	go func() {
		scanner := bufio.NewScanner(rd)
		scanner.Buffer(make([]byte, 4096), 1024*1024)
		for scanner.Scan() {
			if line := strings.TrimSpace(scanner.Text()); line != "" {
				c.log(line)
			}
		}
		if err := scanner.Err(); err != nil {
			c.log("Engine log read failed: " + err.Error())
			_, _ = io.Copy(io.Discard, rd)
		}
		e := cmd.Wait()
		c.mu.Lock()
		c.cmd, c.session = nil, ""
		c.logUnsafe(fmt.Sprintf("Native engine exited: %v", e))
		c.mu.Unlock()
		// This directory belongs to the exited engine; its jobs cannot be replayed.
		_ = os.RemoveAll(inbox)
	}()
	return nil
}
func (c *Controller) engineStop() map[string]any {
	c.workflowStop()
	c.mu.Lock()
	cmd := c.cmd
	c.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
	c.log("Engine stop requested")
	return c.status()
}
func (c *Controller) queue(ext, source string) (string, error) {
	if ext == "cmd" {
		s, e := validateCommand(source)
		if e != nil {
			return "", e
		}
		source = s + "\n"
	} else if ext == "lua" {
		if len(source) > 20000 || strings.TrimSpace(source) == "" {
			return "", errors.New("Lua source must be 1–20,000 characters")
		}
	} else {
		return "", errors.New("Invalid queue type")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.checkBridgeLocked(); err != nil {
		return "", err
	}
	id := randomID()
	dir := filepath.Join(c.bridgeDir, "inbox", c.session)
	temp := filepath.Join(dir, id+".tmp")
	final := filepath.Join(dir, id+"."+ext)
	if err := os.WriteFile(temp, []byte(source), 0600); err != nil {
		return "", err
	}
	if err := os.Rename(temp, final); err != nil {
		_ = os.Remove(temp)
		return "", err
	}
	return id, nil
}
func (c *Controller) checkBridge() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.checkBridgeLocked()
}
func (c *Controller) checkBridgeLocked() error {
	if c.cmd == nil {
		return errors.New("Native engine is stopped")
	}
	h, ok := c.readHeartbeat(c.session)
	if !ok {
		return errors.New("Engine connection status is unavailable. Start the matching ALKO engine build and check its log.")
	}
	if h.Connection != "connected" {
		return fmt.Errorf("Growtopia relay %s (HTTPS bootstrap: %s). Command was not queued.", h.Connection, h.Bootstrap)
	}
	return nil
}
func (c *Controller) scan() (map[string]any, error) {
	path := filepath.Join(c.bridgeDir, "telemetry", "scan.json")
	fi, e := os.Stat(path)
	if os.IsNotExist(e) {
		return map[string]any{"data": func() map[string]any { v, _ := normalizeScan(map[string]any{}); return v }(), "source": "none", "updated_at": nil}, nil
	}
	if e != nil {
		return nil, e
	}
	if fi.Size() > 2000000 {
		return nil, errors.New("Scan telemetry too large")
	}
	b, e := os.ReadFile(path)
	if e != nil {
		return nil, e
	}
	v := map[string]any{}
	if e = json.Unmarshal(b, &v); e != nil {
		return nil, e
	}
	n, e := normalizeScan(v)
	if e != nil {
		return nil, e
	}
	return map[string]any{"data": n, "source": "engine or import", "updated_at": fi.ModTime().Unix()}, nil
}
func numeric(v any, zero int) int {
	switch x := v.(type) {
	case float64:
		return int(x)
	case int:
		return x
	case json.Number:
		n, e := x.Int64()
		if e == nil {
			return int(n)
		}
	}
	return zero
}
func str(v any, fallback string) string {
	if v == nil {
		return fallback
	}
	s, ok := v.(string)
	if !ok {
		return fallback
	}
	return s
}
func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
func normalizeRows(v any) ([]map[string]any, error) {
	if v == nil {
		return []map[string]any{}, nil
	}
	a, ok := v.([]any)
	if !ok {
		return nil, errors.New("Scan items must be an array")
	}
	out := []map[string]any{}
	for i, item := range a {
		if i >= 600 {
			break
		}
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		id := numeric(m["id"], -1)
		cnt := numeric(m["count"], -1)
		if id < 0 || cnt < 0 || cnt > 1000000 {
			continue
		}
		name := str(m["name"], fmt.Sprintf("Item #%d", id))
		if len(name) > 90 {
			name = name[:90]
		}
		out = append(out, map[string]any{"id": id, "name": name, "count": cnt})
	}
	sort.SliceStable(out, func(i, j int) bool {
		ai, aj := out[i]["count"].(int), out[j]["count"].(int)
		if ai != aj {
			return ai > aj
		}
		return out[i]["name"].(string) < out[j]["name"].(string)
	})
	return out, nil
}
func normalizeScan(m map[string]any) (map[string]any, error) {
	result := map[string]any{}
	total := map[string]int{}
	for _, part := range []string{"foreground", "background", "dropped"} {
		a, e := normalizeRows(m[part])
		if e != nil {
			return nil, e
		}
		result[part] = a
		sum := 0
		for _, r := range a {
			sum += r["count"].(int)
		}
		total[part] = sum
	}
	size, _ := m["size"].(map[string]any)
	if size == nil {
		size = map[string]any{}
	}
	w := clamp(numeric(size["width"], 0), 0, 500)
	h := clamp(numeric(size["height"], 0), 0, 500)
	name := str(m["world"], "Current world")
	if strings.TrimSpace(name) == "" {
		name = "Current world"
	}
	if len(name) > 64 {
		name = name[:64]
	}
	result["world"] = name
	result["size"] = map[string]int{"width": w, "height": h}
	result["totals"] = total
	return result, nil
}
func (c *Controller) scanImport(m map[string]any) (map[string]any, error) {
	clean, e := normalizeScan(m)
	if e != nil {
		return nil, e
	}
	path := filepath.Join(c.bridgeDir, "telemetry", "scan.json")
	temp := path + ".tmp"
	b, _ := json.Marshal(clean)
	if e = os.WriteFile(temp, b, 0600); e != nil {
		return nil, e
	}
	if e = os.Rename(temp, path); e != nil {
		return nil, e
	}
	c.log("Manual world scan imported")
	return clean, nil
}
func (c *Controller) workflowState() WFState { c.mu.Lock(); defer c.mu.Unlock(); return c.wf }
func (c *Controller) workflowStart(name string, steps []Step, repeat int) (WFState, error) {
	if len(steps) < 1 || len(steps) > 30 {
		return WFState{}, errors.New("A workflow needs 1–30 steps")
	}
	if repeat < 1 || repeat > 20 {
		return WFState{}, errors.New("Repeat must be 1–20")
	}
	for i := range steps {
		s := &steps[i]
		if s.Command != "" {
			cmd, e := validateCommand(s.Command)
			if e != nil {
				return WFState{}, e
			}
			s.Command = cmd
		} else if s.WaitMS < 400 || s.WaitMS > 60000 {
			return WFState{}, errors.New("Wait must be 400–60,000 ms")
		}
	}
	c.mu.Lock()
	if c.wfActive {
		c.mu.Unlock()
		return WFState{}, errors.New("Another workflow is already running")
	}
	if len(name) > 60 {
		name = name[:60]
	}
	c.wf = WFState{Running: true, Name: name, Completed: 0, Total: len(steps) * repeat, Error: nil}
	c.wfActive = true
	stop := make(chan struct{})
	c.wfStop = stop
	initial := c.wf
	c.mu.Unlock()
	go func() {
		defer func() { c.mu.Lock(); c.wf.Running = false; c.wfActive = false; c.mu.Unlock() }()
		var prev time.Time
		for j := 0; j < repeat; j++ {
			for _, s := range steps {
				select {
				case <-stop:
					return
				default:
				}
				if s.Command != "" {
					remain := 400*time.Millisecond - time.Since(prev)
					if !prev.IsZero() && remain > 0 {
						select {
						case <-stop:
							return
						case <-time.After(remain):
						}
					}
					if _, e := c.queue("cmd", s.Command); e != nil {
						c.mu.Lock()
						c.wf.Error = e.Error()
						c.mu.Unlock()
						return
					}
					prev = time.Now()
				} else {
					select {
					case <-stop:
						return
					case <-time.After(time.Duration(s.WaitMS) * time.Millisecond):
					}
				}
				c.mu.Lock()
				c.wf.Completed++
				c.mu.Unlock()
			}
		}
	}()
	return initial, nil
}
func (c *Controller) workflowStop() WFState {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.wfStop != nil {
		select {
		case <-c.wfStop:
		default:
			close(c.wfStop)
		}
	}
	c.wf.Running = false
	return c.wf
}

type API struct {
	c    *Controller
	port int
}

func jsonOut(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Security-Policy", "default-src 'none'")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}
func bad(w http.ResponseWriter, e error) { jsonOut(w, 400, map[string]string{"error": e.Error()}) }
func decode(r *http.Request) (map[string]any, error) {
	defer r.Body.Close()
	data, err := io.ReadAll(io.LimitReader(r.Body, 100001))
	if err != nil {
		return nil, err
	}
	if len(data) > 100000 {
		return nil, errors.New("Request too large")
	}
	m := map[string]any{}
	if err = json.Unmarshal(data, &m); err != nil {
		return nil, err
	}
	return m, nil
}
func (a *API) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Path
	if r.Method == http.MethodGet {
		switch p {
		case "/api/status":
			jsonOut(w, 200, a.c.status())
			return
		case "/api/settings":
			a.c.mu.Lock()
			s := copySettings(a.c.settings)
			a.c.mu.Unlock()
			jsonOut(w, 200, s)
			return
		case "/api/logs":
			a.c.mu.Lock()
			s := append([]logItem{}, a.c.logs...)
			a.c.mu.Unlock()
			jsonOut(w, 200, map[string]any{"logs": s})
			return
		case "/api/scan":
			result, e := a.c.scan()
			if e != nil {
				bad(w, e)
			} else {
				jsonOut(w, 200, result)
			}
			return
		case "/api/commands":
			keys := []string{}
			for k := range allowed {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			jsonOut(w, 200, map[string]any{"names": keys})
			return
		}
		if p == "/" {
			p = "/index.html"
		}
		p = strings.TrimPrefix(p, "/")
		if p != "index.html" && p != "style.css" && p != "app.js" {
			http.NotFound(w, r)
			return
		}
		data, e := fs.ReadFile(assets, "web/"+p)
		if e != nil {
			http.NotFound(w, r)
			return
		}
		if p == "index.html" {
			data = []byte(strings.ReplaceAll(string(data), "__CSRF_TOKEN__", a.c.token))
		}
		t := "text/html; charset=utf-8"
		if strings.HasSuffix(p, ".js") {
			t = "application/javascript; charset=utf-8"
		}
		if strings.HasSuffix(p, ".css") {
			t = "text/css; charset=utf-8"
		}
		w.Header().Set("Content-Type", t)
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'")
		_, _ = w.Write(data)
		return
	}
	if r.Method != http.MethodPost || !strings.HasPrefix(p, "/api/") {
		jsonOut(w, 405, map[string]string{"error": "Method not allowed"})
		return
	}
	origin := r.Header.Get("Origin")
	if origin != "" && origin != fmt.Sprintf("http://127.0.0.1:%d", a.port) {
		jsonOut(w, 403, map[string]string{"error": "Only local dashboard may issue commands"})
		return
	}
	if r.Header.Get("X-ALKO-Token") != a.c.token {
		jsonOut(w, 403, map[string]string{"error": "Invalid dashboard token"})
		return
	}
	m, e := decode(r)
	if e != nil {
		bad(w, e)
		return
	}
	var result any
	switch p {
	case "/api/settings":
		result, e = a.c.saveSettings(m)
	case "/api/engine/start":
		result, e = a.c.engineStart()
	case "/api/engine/stop":
		result = a.c.engineStop()
	case "/api/scan/import":
		var scan map[string]any
		scan, e = a.c.scanImport(m)
		result = map[string]any{"data": scan}
	case "/api/command":
		cmd, er := validateCommand(str(m["command"], ""))
		if er != nil {
			e = er
			break
		}
		a.c.mu.Lock()
		confirm, _ := a.c.settings["confirm_trash"].(bool)
		a.c.mu.Unlock()
		if strings.HasPrefix(strings.ToLower(cmd), "/qtrash") && confirm && m["confirm"] != true {
			e = errors.New("Trash action requires explicit confirmation")
			break
		}
		var id string
		id, e = a.c.queue("cmd", cmd)
		result = map[string]any{"queued": true, "id": id, "command": cmd}
		if e == nil {
			a.c.log("Queued command: " + cmd)
		}
	case "/api/scripts/run":
		a.c.mu.Lock()
		enabled, _ := a.c.settings["allow_lua"].(bool)
		a.c.mu.Unlock()
		if !enabled {
			e = errors.New("Enable custom Lua executor in Settings first")
			break
		}
		var id string
		id, e = a.c.queue("lua", str(m["source"], ""))
		result = map[string]any{"queued": true, "id": id}
		if e == nil {
			a.c.log("Queued Lua script (source not logged)")
		}
	case "/api/workflow/start":
		if e = a.c.checkBridge(); e != nil {
			break
		}
		raw, ok := m["steps"].([]any)
		if !ok {
			e = errors.New("Steps must be an array")
			break
		}
		steps := []Step{}
		for _, v := range raw {
			item, ok := v.(map[string]any)
			if !ok {
				e = errors.New("Workflow steps must be objects")
				break
			}
			s := Step{}
			if cmd, ok := item["command"].(string); ok {
				s.Command = cmd
			} else {
				s.WaitMS = numeric(item["wait_ms"], 0)
			}
			steps = append(steps, s)
		}
		if e != nil {
			break
		}
		var wf WFState
		wf, e = a.c.workflowStart(str(m["name"], "Unnamed"), steps, numeric(m["repeat"], 1))
		result = wf
	case "/api/workflow/stop":
		result = a.c.workflowStop()
	case "/api/app/quit":
		result = map[string]any{"quitting": true}
		go func() { time.Sleep(300 * time.Millisecond); a.c.engineStop(); os.Exit(0) }()
	default:
		jsonOut(w, 404, map[string]string{"error": "Unknown endpoint"})
		return
	}
	if e != nil {
		bad(w, e)
	} else {
		jsonOut(w, 200, result)
	}
}
func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	case "darwin":
		cmd = exec.Command("open", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	_ = cmd.Start()
}
func initRuntime() (string, error) {
	base, e := os.UserConfigDir()
	if e != nil {
		return "", e
	}
	dir := filepath.Join(base, "ALKO-Proxy")
	e = os.MkdirAll(dir, 0700)
	return dir, e
}
func main() {
	port := flag.Int("port", 8765, "Local web port")
	noBrowser := flag.Bool("no-browser", false, "Do not launch system browser")
	flag.Parse()
	dir, e := initRuntime()
	if e != nil {
		log.Fatal(e)
	}
	c, e := newController(dir)
	if e != nil {
		log.Fatal(e)
	}
	api := &API{c: c, port: *port}
	address := fmt.Sprintf("127.0.0.1:%d", *port)
	listener, e := net.Listen("tcp", address)
	if e != nil {
		if !*noBrowser {
			openBrowser("http://" + address)
		}
		fmt.Fprintln(os.Stderr, "ALKO local port is already in use:", e)
		return
	}
	fmt.Printf("ALKO Proxy dashboard: http://%s\nLocal data: %s\nNative engine: not bundled / unverified on v5.61\n", address, dir)
	if !*noBrowser {
		go func() { time.Sleep(400 * time.Millisecond); openBrowser("http://" + address) }()
	}
	if e = http.Serve(listener, api); e != nil {
		log.Println(e)
	}
}
