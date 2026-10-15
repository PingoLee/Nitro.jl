// Go net/http reference server for bench/socket (#469). It answers the routes server.jl answers,
// with the same bodies, so run.sh's `go` mode differs from the Julia modes only in what serves
// them. Go is the reference, not the target: the point is to know which part of the gap is
// HTTP.jl, which is the Julia runtime and which is Nitro.
//
//	PORT=8080     Loopback port.
//	CPU_MS=50     What /cpu burns: a loop that never blocks, as in server.jl. Unlike Julia, Go
//	              preempts it asynchronously (since Go 1.14), so it does not hold its P to the end.
//	LAG=0|1       Start the /lag probe, as in server.jl.
//
// GOMAXPROCS is set by run.sh to the number of server CPUs. Every response is built per request,
// as in every other mode: no cached bodies, no cached headers.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"runtime"
	"sort"
	"strconv"
	"sync"
	"time"
)

const plaintext = "Hello, World!"

// burn computes for ms milliseconds without blocking: the same clock-read loop as server.jl.
func burn(ms float64) float64 {
	deadline := time.Now().Add(time.Duration(ms * float64(time.Millisecond)))
	x := 0.0
	for time.Now().Before(deadline) {
		x = math.Sin(x + 1.0)
	}
	return x
}

var (
	lagMu sync.Mutex
	lagMs []float64
)

// lagProbe records how late a 10 ms sleep wakes, as server.jl's probe does.
func lagProbe() {
	for {
		t0 := time.Now()
		time.Sleep(10 * time.Millisecond)
		late := float64(time.Since(t0).Nanoseconds())/1e6 - 10.0
		lagMu.Lock()
		lagMs = append(lagMs, late)
		lagMu.Unlock()
	}
}

func lagBody() []byte {
	lagMu.Lock()
	s := lagMs
	lagMs = nil
	lagMu.Unlock()
	if len(s) == 0 {
		b, _ := json.Marshal(map[string]int{"n": 0})
		return b
	}
	sort.Float64s(s)
	q := func(p float64) float64 {
		i := int(math.Ceil(p*float64(len(s)))) - 1
		i = max(0, min(i, len(s)-1))
		return math.Round(s[i]*100) / 100
	}
	b, _ := json.Marshal(map[string]any{"n": len(s), "p50": q(0.5), "p99": q(0.99),
		"max": math.Round(s[len(s)-1]*100) / 100})
	return b
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	cpuMs := 50.0
	if v := os.Getenv("CPU_MS"); v != "" {
		f, err := strconv.ParseFloat(v, 64)
		if err != nil {
			log.Fatalf("CPU_MS: %v", err)
		}
		cpuMs = f
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /plaintext", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte(plaintext))
	})
	mux.HandleFunc("GET /json", func(w http.ResponseWriter, r *http.Request) {
		// A map, as server.jl's `Dict`, marshalled per request.
		b, _ := json.Marshal(map[string]string{"message": "Hello, World!"})
		w.Header().Set("Content-Type", "application/json")
		w.Write(b)
	})
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("GET /cpu", func(w http.ResponseWriter, r *http.Request) {
		x := burn(cpuMs)
		fmt.Fprintf(w, "ok %v", x > 2.0)
	})
	mux.HandleFunc("GET /lag", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write(lagBody())
	})

	if os.Getenv("LAG") == "1" {
		go lagProbe()
	}
	log.Printf("bench: serving MODE=go PORT=%s GOMAXPROCS=%d %s", port, runtime.GOMAXPROCS(0), runtime.Version())
	log.Fatal(http.ListenAndServe("127.0.0.1:"+port, mux))
}
