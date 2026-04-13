package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime/debug"
)

func main() {
	info, _ := debug.ReadBuildInfo()
	revision := "unknown"
	for _, s := range info.Settings {
		if s.Key == "vcs.revision" {
			revision = s.Value
			break
		}
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		hostname, _ := os.Hostname()
		fmt.Fprintf(w, "reproducible-demo\n  go:       %s\n  revision: %s\n  host:     %s\n",
			info.GoVersion, revision, hostname)
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})

	addr := ":8080"
	log.Printf("listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}
