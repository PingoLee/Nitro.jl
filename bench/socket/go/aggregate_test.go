package main

import (
	"fmt"
	"testing"
)

// The kernel alone, no HTTP (#590 H1): go test -bench Aggregate -benchtime 3s
// Each sub-benchmark also reports ns/row, the unit the Julia rows in ../../suite/aggregate.jl
// are compared in.
var benchRows = aggRows(10_000_000)

var sinkF float64
var sinkM map[int]float64

func BenchmarkAggregate(b *testing.B) {
	for _, op := range []string{"sum", "mean", "groupby"} {
		for _, n := range []int{1_000, 100_000, 10_000_000} {
			b.Run(fmt.Sprintf("%s/n=%d", op, n), func(b *testing.B) {
				for i := 0; i < b.N; i++ {
					switch op {
					case "sum":
						sinkF = aggSum(benchRows, n)
					case "mean":
						sinkF = aggMean(benchRows, n)
					case "groupby":
						sinkM = aggGroupBy(benchRows, n)
					}
				}
				b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N)/float64(n), "ns/row")
			})
		}
	}
}

// The checksum the Julia side prints too: both languages must aggregate the same numbers.
func TestAggregateChecksum(t *testing.T) {
	g := aggGroupBy(benchRows, 1_000)
	t.Logf("sum(n=10^7)=%.6f mean(n=1000)=%.9f groupby(n=1000)[7]=%.9f keys=%d",
		aggSum(benchRows, 10_000_000), aggMean(benchRows, 1_000), g[7], len(g))
}
