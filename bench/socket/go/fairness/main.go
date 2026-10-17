// Command fairness keeps C keep-alive connections busy on one URL for a duration, each with its
// own connection and one request at a time, and reports how evenly the server served them (#590):
// requests completed per connection, every request's latency, and each connection's longest wait.
// oha reports only pooled percentiles, which cannot tell a server that is slow for everyone from
// one that serves most connections at once and leaves a few waiting.
//
//	go build -o fairness ./fairness && ./fairness -url http://127.0.0.1:8080/aggregate?n=100000&op=groupby -c 500 -d 8s
//
// -stamp tags every request with X-Conn (its connection's index), X-Seq (its number on that
// connection) and X-Sent (the wall clock at send, Unix ns), which server.jl's PROBE=1 records
// beside its own stamps (#618). -trace <file> writes one TSV line per completed request: conn,
// seq, sent ns, received ns, so the two can be joined on (conn, seq).
//
// Prints one JSON object.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"sort"
	"strconv"
	"sync"
	"time"
)

type conn struct {
	count   int
	errors  int
	maxWait time.Duration
	lat     []time.Duration
	trace   [][3]int64 // seq, sent, received (Unix ns), with -trace
}

func pct(sorted []float64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	i := int(math.Ceil(p*float64(len(sorted)))) - 1
	if i < 0 {
		i = 0
	}
	return sorted[i]
}

func main() {
	url := flag.String("url", "", "target URL")
	c := flag.Int("c", 500, "connections")
	d := flag.Duration("d", 8*time.Second, "duration")
	stamp := flag.Bool("stamp", false, "send X-Conn, X-Seq and X-Sent headers")
	tracePath := flag.String("trace", "", "write one TSV line per request (conn, seq, sent ns, received ns) here")
	flag.Parse()
	if *url == "" {
		fmt.Fprintln(os.Stderr, "fairness: -url is required")
		os.Exit(2)
	}

	conns := make([]conn, *c)
	var wg sync.WaitGroup
	start := time.Now()
	deadline := start.Add(*d)
	for i := range conns {
		wg.Add(1)
		go func(idx int, cs *conn) {
			defer wg.Done()
			// One transport per goroutine: its own keep-alive connection, never shared.
			client := &http.Client{Transport: &http.Transport{MaxIdleConnsPerHost: 1, DisableCompression: true}}
			req, err := http.NewRequest("GET", *url, nil)
			if err != nil {
				fmt.Fprintln(os.Stderr, "fairness:", err)
				os.Exit(2)
			}
			connID := strconv.Itoa(idx)
			for seq := 0; time.Now().Before(deadline); seq++ {
				t0 := time.Now()
				if *stamp {
					req.Header.Set("X-Conn", connID)
					req.Header.Set("X-Seq", strconv.Itoa(seq))
					req.Header.Set("X-Sent", strconv.FormatInt(t0.UnixNano(), 10))
				}
				resp, err := client.Do(req)
				if err == nil {
					_, err = io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
				}
				l := time.Since(t0)
				if err != nil {
					cs.errors++
					continue
				}
				cs.count++
				cs.lat = append(cs.lat, l)
				if l > cs.maxWait {
					cs.maxWait = l
				}
				if *tracePath != "" {
					cs.trace = append(cs.trace, [3]int64{int64(seq), t0.UnixNano(), t0.Add(l).UnixNano()})
				}
			}
		}(i, &conns[i])
	}
	wg.Wait()
	wall := time.Since(start).Seconds()
	if *tracePath != "" {
		f, err := os.Create(*tracePath)
		if err != nil {
			fmt.Fprintln(os.Stderr, "fairness:", err)
			os.Exit(1)
		}
		w := bufio.NewWriter(f)
		for i, cs := range conns {
			for _, t := range cs.trace {
				fmt.Fprintf(w, "%d\t%d\t%d\t%d\n", i, t[0], t[1], t[2])
			}
		}
		w.Flush()
		f.Close()
	}

	var all, counts, maxWaits []float64
	total, errs := 0, 0
	sum, sumSq := 0.0, 0.0
	for _, cs := range conns {
		total += cs.count
		errs += cs.errors
		counts = append(counts, float64(cs.count))
		maxWaits = append(maxWaits, cs.maxWait.Seconds()*1e3)
		sum += float64(cs.count)
		sumSq += float64(cs.count) * float64(cs.count)
		for _, l := range cs.lat {
			all = append(all, l.Seconds()*1e3)
		}
	}
	sort.Float64s(all)
	sort.Float64s(counts)
	sort.Float64s(maxWaits)
	over1s := 0
	for _, l := range all {
		if l > 1000 {
			over1s++
		}
	}
	jain := 0.0
	if sumSq > 0 {
		jain = sum * sum / (float64(len(conns)) * sumSq)
	}
	out := map[string]any{
		"connections": *c, "seconds": wall, "requests": total, "errors": errs,
		"rps":                  float64(total) / wall,
		"latency_ms":           map[string]float64{"p50": pct(all, 0.5), "p90": pct(all, 0.9), "p99": pct(all, 0.99), "p999": pct(all, 0.999), "max": pct(all, 1)},
		"share_over_1s":        float64(over1s) / math.Max(float64(len(all)), 1),
		"per_conn_count":       map[string]float64{"min": counts[0], "p1": pct(counts, 0.01), "p10": pct(counts, 0.1), "p50": pct(counts, 0.5), "p90": pct(counts, 0.9), "max": counts[len(counts)-1]},
		"jain_index":           jain,
		"per_conn_max_wait_ms": map[string]float64{"p10": pct(maxWaits, 0.1), "p50": pct(maxWaits, 0.5), "p90": pct(maxWaits, 0.9), "max": maxWaits[len(maxWaits)-1]},
	}
	enc := json.NewEncoder(os.Stdout)
	enc.Encode(out)
}
