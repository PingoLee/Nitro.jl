// Process-level task measurements, Go side (#469 part 2): the ones a `testing.B` cannot express
// because they are about memory or about the scheduler under load. Twin of ../tasks.jl.
//
//	./tasks parked   100,000 goroutines blocked on one channel: creation time and memory per goroutine
//	./tasks spin     one CPU-bound goroutine per P: how late a 1 ms sleeper wakes
//
// `GODEBUG=asyncpreemptoff=1 ./tasks spin` turns Go's asynchronous preemption off, which is
// Julia's cooperative model reproduced in Go itself.
package main

import (
	"fmt"
	"os"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// rssKiB reads VmRSS from /proc, so Go and Julia report memory the same way.
func rssKiB() int64 {
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return -1
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "VmRSS:") {
			n, _ := strconv.ParseInt(strings.Fields(line)[1], 10, 64)
			return n
		}
	}
	return -1
}

func parked() {
	const n = 100_000
	runtime.GC()
	var ms0, ms1 runtime.MemStats
	runtime.ReadMemStats(&ms0)
	rss0 := rssKiB()
	release := make(chan struct{})
	var started atomic.Int64
	var wg sync.WaitGroup
	t0 := time.Now()
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func() { started.Add(1); <-release; wg.Done() }()
	}
	// A goroutine that has not run yet has no stack in use; count only once every one is parked.
	for started.Load() < n {
		runtime.Gosched()
	}
	create := time.Since(t0)
	runtime.ReadMemStats(&ms1)
	rss1 := rssKiB()
	t1 := time.Now()
	close(release)
	wg.Wait()
	wake := time.Since(t1)
	stack := int64(ms1.StackInuse) - int64(ms0.StackInuse)
	heap := int64(ms1.HeapInuse) - int64(ms0.HeapInuse)
	fmt.Printf("parked\tgo\t%d\tcreate_ns_per_task=%.0f\twake_all_ns_per_task=%.0f\trss_kib_per_task=%.2f\tstack_plus_heap_kib_per_task=%.2f\n",
		n, float64(create.Nanoseconds())/n, float64(wake.Nanoseconds())/n,
		float64(rss1-rss0)/n, float64(stack+heap)/1024/n)
}

var sink uint64

// A loop with no call, no allocation and no channel op: only asynchronous preemption stops it.
func spinLoop(iters uint64) uint64 {
	var x uint64 = 1
	for i := uint64(0); i < iters; i++ {
		x = x*6364136223846793005 + i
	}
	return x
}

// spinAll starts n spinners of iters and returns a WaitGroup plus the longest one's wall time,
// valid once the group is done.
func spinAll(n int, iters uint64) (*sync.WaitGroup, *atomic.Int64) {
	var wg sync.WaitGroup
	var longest atomic.Int64
	wg.Add(n)
	for i := 0; i < n; i++ {
		go func() {
			defer wg.Done()
			t := time.Now()
			atomic.AddUint64(&sink, spinLoop(iters))
			d := int64(time.Since(t))
			for {
				cur := longest.Load()
				if d <= cur || longest.CompareAndSwap(cur, d) {
					break
				}
			}
		}()
	}
	return &wg, &longest
}

func spin() {
	procs := runtime.GOMAXPROCS(0)
	// Calibrate with every spinner running at once, as tasks.jl does.
	const probe = 100_000_000
	wg, longest := spinAll(procs, probe)
	wg.Wait()
	iters := uint64(float64(probe) * 1.5 / time.Duration(longest.Load()).Seconds())

	wg, longest = spinAll(procs, iters) // every P busy
	// The "other request", a goroutine of its own as in tasks.jl: wants to wake at
	// spawned + k ms, and is charged lateness against that schedule from the moment it was spawned.
	lat := make([]float64, 0, 100)
	spawned := time.Now()
	hbDone := make(chan struct{})
	go func() {
		for k := 1; k <= 100; k++ {
			due := spawned.Add(time.Duration(k) * time.Millisecond)
			if d := time.Until(due); d > 0 {
				time.Sleep(d)
			}
			lat = append(lat, float64(time.Since(due).Nanoseconds())/1e6)
		}
		close(hbDone)
	}()
	<-hbDone
	wg.Wait()
	sort.Float64s(lat)
	label := "go"
	if strings.Contains(os.Getenv("GODEBUG"), "asyncpreemptoff=1") {
		label = "go_asyncpreemptoff"
	}
	fmt.Printf("spin\t%s\t%d spinners\tlateness_p50_ms=%.3f\tlateness_p99_ms=%.3f\tlateness_max_ms=%.3f\tlongest_spinner_s=%.3f\n",
		label, procs, lat[50], lat[98], lat[99], time.Duration(longest.Load()).Seconds())
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: tasks parked|spin")
		os.Exit(2)
	}
	fmt.Fprintf(os.Stderr, "%s GOMAXPROCS=%d GODEBUG=%q\n", runtime.Version(), runtime.GOMAXPROCS(0), os.Getenv("GODEBUG"))
	switch os.Args[1] {
	case "parked":
		parked()
	case "spin":
		spin()
	default:
		fmt.Fprintln(os.Stderr, "usage: tasks parked|spin")
		os.Exit(2)
	}
}
