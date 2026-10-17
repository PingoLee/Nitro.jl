package main

// The in-memory aggregation behind /aggregate (#590): the same generator and the same loops as
// ../aggregate.jl. Compare the two files line for line before changing either.
//
// Rows come from splitmix64 with a fixed seed, so Go aggregates exactly the numbers Julia does.
// The kernels are plain loops over the first n rows: no goroutine fan-out, no unsafe, no
// assembly. map[int]float64 against Julia's Dict{Int,Float64}.

type aggRow struct {
	ID    int
	Key   int
	Value float64
}

const (
	aggKeys = 100
	aggSeed = uint64(0x2a)
)

// splitmix64 returns the new state and its output.
func splitmix64(state uint64) (uint64, uint64) {
	state += 0x9e3779b97f4a7c15
	z := state
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return state, z ^ (z >> 31)
}

// aggRows builds row i (1-based id): key = one draw mod 100, value = the next draw's top 53 bits
// scaled to [0, 1000).
func aggRows(n int) []aggRow {
	rows := make([]aggRow, n)
	state := aggSeed
	var a, b uint64
	for i := range rows {
		state, a = splitmix64(state)
		state, b = splitmix64(state)
		rows[i] = aggRow{ID: i + 1, Key: int(a % aggKeys), Value: float64(b>>11) * 0x1p-53 * 1000.0}
	}
	return rows
}

func aggSum(rows []aggRow, n int) float64 {
	s := 0.0
	for _, r := range rows[:n] {
		s += r.Value
	}
	return s
}

func aggMean(rows []aggRow, n int) float64 { return aggSum(rows, n) / float64(n) }

func aggGroupBy(rows []aggRow, n int) map[int]float64 {
	sums := make(map[int]float64)
	for _, r := range rows[:n] {
		sums[r.Key] += r.Value
	}
	return sums
}
