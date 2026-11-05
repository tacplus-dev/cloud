// Copyright (c) 2026 Jody Scott
// SPDX-License-Identifier: Apache-2.0

// A stub HTTP API for tests/gitlab_plan_test.sh: it answers each request whose method and escaped path a fixture
// names ("GET /api/v4/metadata") with that fixture's JSON, and anything else with 404. It writes nothing anywhere
// but its log: every request, one line ("METHOD path status"), so that a test sees what a plan asked for. It listens
// on 127.0.0.1, on a free port it writes to ADDR_FILE once it listens. Standard library only.
//
//	go run tests/stubapi/main.go FIXTURE.json LOG ADDR_FILE
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"sync"
)

func main() {
	if len(os.Args) != 4 {
		log.Fatal("usage: main.go FIXTURE.json LOG ADDR_FILE")
	}
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		log.Fatal(err)
	}
	routes := map[string]json.RawMessage{}
	if err := json.Unmarshal(raw, &routes); err != nil {
		log.Fatalf("%s: %v", os.Args[1], err)
	}
	logFile, err := os.OpenFile(os.Args[2], os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		log.Fatal(err)
	}
	var mu sync.Mutex
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	if err := os.WriteFile(os.Args[3], []byte(l.Addr().String()), 0o644); err != nil {
		log.Fatal(err)
	}
	log.Fatal(http.Serve(l, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := r.Method + " " + r.URL.EscapedPath()
		body, found := routes[key]
		status := http.StatusOK
		if !found {
			status, body = http.StatusNotFound, json.RawMessage(`{"message":"404 Not Found"}`)
		}
		mu.Lock()
		fmt.Fprintf(logFile, "%s %d\n", key, status)
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write(body)
	})))
}
