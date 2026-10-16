// Task-primitive micro-benchmarks, Go side (#469 part 2). Each has a twin of the same shape in
// ../tasks.jl; run both through ../run.sh so they share the CPUs and the thread count.
//
//	go test -bench . -benchmem -count 5
package main

import (
	"sync"
	"testing"
)

var sinkInt int

//go:noinline
func tinyWork() int { return len("pong") }

// Spawn one goroutine and wait for it, one at a time. Julia: wait(Threads.@spawn _tiny_work()),
// which is bench/suite/taskpattern.jl's `spawn_single` and the shape of Nitro's per-request spawn.
func BenchmarkSpawnWait(b *testing.B) {
	for i := 0; i < b.N; i++ {
		var r int
		done := make(chan struct{})
		go func() { r = tinyWork(); close(done) }()
		<-done
		sinkInt += r
	}
}

// One round trip between two goroutines over unbuffered channels: two context switches.
func BenchmarkPingPong(b *testing.B) {
	a, c := make(chan int), make(chan int)
	go func() {
		for v := range a {
			c <- v
		}
	}()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		a <- i
		<-c
	}
	b.StopTimer()
	close(a)
}

// Fan-out under contention: 1000 goroutines that each do a tiny bit of work, then one wait for
// all of them. One op is the whole fan-out; `ns/task` divides it by 1000. JuliaLang/julia#63416
// measures this shape.
const fanOutN = 1000

func BenchmarkFanOut1000(b *testing.B) {
	results := make([]int, fanOutN)
	for i := 0; i < b.N; i++ {
		var wg sync.WaitGroup
		wg.Add(fanOutN)
		for j := 0; j < fanOutN; j++ {
			go func(j int) { results[j] = tinyWork(); wg.Done() }(j)
		}
		wg.Wait()
	}
	b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N*fanOutN), "ns/task")
}
