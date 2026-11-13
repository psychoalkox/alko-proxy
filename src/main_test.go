package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateCommands(t *testing.T) {
	for _, s := range []string{"/alko", "/gscan", "/warp START", "/qdrop 242 5", "/qtrash 242 1"} {
		if _, err := validateCommand(s); err != nil {
			t.Errorf("%q rejected: %v", s, err)
		}
	}
	for _, s := range []string{"no command", "/warp ../secret", "/qtrash 242 900", "/fake", "/warp ; rm -rf /"} {
		if _, err := validateCommand(s); err == nil {
			t.Errorf("%q unexpectedly accepted", s)
		}
	}
}
func TestScanNormalize(t *testing.T) {
	var scan map[string]any
	err := json.Unmarshal([]byte(`{"world":"ALKO","size":{"width":100,"height":60},"foreground":[{"id":242,"name":"Sugar Cane","count":100},{"id":243,"count":3}]}`), &scan)
	if err != nil {
		t.Fatal(err)
	}
	n, err := normalizeScan(scan)
	if err != nil {
		t.Fatal(err)
	}
	totals := n["totals"].(map[string]int)
	if totals["foreground"] != 103 {
		t.Fatalf("unexpected scan count %v", totals)
	}
}
func TestControllerAndQueue(t *testing.T) {
	dir := t.TempDir()
	c, err := newController(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = c.queue("cmd", "/warp START"); err != nil {
		t.Fatal(err)
	}
	files, err := os.ReadDir(filepath.Join(dir, "bridge", "inbox"))
	if err != nil || len(files) != 1 {
		t.Fatalf("queue files %v %v", files, err)
	}
	if _, err = c.queue("lua", "print('hello')"); err != nil {
		t.Fatal(err)
	}
	if _, err = c.queue("cmd", "/warp bad-name"); err == nil {
		t.Fatal("invalid command accepted")
	}
	result, err := c.scanImport(map[string]any{"world": "ALKO", "foreground": []any{map[string]any{"id": float64(242), "count": float64(100)}}})
	if err != nil {
		t.Fatal(err)
	}
	if result["world"] != "ALKO" {
		t.Fatal("import mismatch")
	}
	st, err := c.scan()
	if err != nil {
		t.Fatal(err)
	}
	if st["source"] != "engine or import" {
		t.Fatal("import telemetry missing")
	}
	_, err = c.engineStart()
	if err == nil || !strings.Contains(err.Error(), "not included") {
		t.Fatalf("expected engine missing error, got %v", err)
	}
}
