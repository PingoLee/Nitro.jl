// The database routes of #589 against PostgreSQL, the Go side of server.jl's db/world.jl: the
// same four routes, the same `world` table and the same bodies, through pgx v5's own pool.
//
//	DB=postgres        Serve the routes. Unset: no database, no routes (the Julia-only runs).
//	DB_POOL=<n>        Mirrors PormG's pool: MinConns = n, MaxConns = n * 10, because PormG opens
//	                   a pool at `pool_size` and grows it lazily to `pool_size * 10`. Default 32.
//	DB_CONNINFO_FILE   The libpq conninfo; it carries the password and is never printed.
//
// pgx runs its default query mode, a cached prepared statement per SQL text, which is what a Go
// application runs. Go has no SQLite route: a cgo or transpiled driver would measure the driver.
package main

import (
	"context"
	"fmt"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"slices"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	worldRows  = 10000
	maxQueries = 500
)

func writeRow(b *strings.Builder, id, randomnumber int32) {
	fmt.Fprintf(b, `{"id":%d,"randomnumber":%d}`, id, randomnumber)
}

// queryCount is TechEmpower's: missing or not a number is 1, clamped to 1..maxQueries.
func queryCount(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		return 1
	}
	return max(1, min(n, maxQueries))
}

func randomID() int32 { return int32(rand.IntN(worldRows) + 1) }

// distinctIDs returns n distinct ids, sorted, so concurrent transactions lock rows in one order.
func distinctIDs(n int) []int32 {
	seen := make(map[int32]struct{}, n)
	for len(seen) < n {
		seen[randomID()] = struct{}{}
	}
	ids := make([]int32, 0, n)
	for id := range seen {
		ids = append(ids, id)
	}
	slices.Sort(ids)
	return ids
}

const selectWorld = "SELECT id, randomnumber FROM world WHERE id = $1"

func dbRoutes(mux *http.ServeMux) {
	if os.Getenv("DB") != "postgres" {
		return
	}
	pool := 32
	if v := os.Getenv("DB_POOL"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			log.Fatalf("DB_POOL: %v", err)
		}
		pool = n
	}
	raw, err := os.ReadFile(os.Getenv("DB_CONNINFO_FILE"))
	if err != nil {
		log.Fatalf("DB_CONNINFO_FILE: %v", err)
	}
	cfg, err := pgxpool.ParseConfig(strings.TrimSpace(string(raw)))
	if err != nil {
		log.Fatal("DB_CONNINFO_FILE does not parse") // the error would quote the conninfo
	}
	cfg.MinConns = int32(pool)
	cfg.MaxConns = int32(pool * 10)
	ctx := context.Background()
	db, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		log.Fatal("pgxpool: cannot open the pool")
	}
	var version, maxConns string
	if err := db.QueryRow(ctx, "SHOW server_version").Scan(&version); err != nil {
		log.Fatalf("SHOW server_version: %v", err)
	}
	if err := db.QueryRow(ctx, "SHOW max_connections").Scan(&maxConns); err != nil {
		log.Fatalf("SHOW max_connections: %v", err)
	}
	log.Printf("bench: database backend=postgres pool_min=%d pool_max=%d server_version=%s max_connections=%s",
		cfg.MinConns, cfg.MaxConns, version, maxConns)

	fail := func(w http.ResponseWriter, err error) { http.Error(w, err.Error(), http.StatusInternalServerError) }
	writeJSON := func(w http.ResponseWriter, body string) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(body))
	}

	mux.HandleFunc("GET /db", func(w http.ResponseWriter, r *http.Request) {
		var id, rn int32
		if err := db.QueryRow(r.Context(), selectWorld, randomID()).Scan(&id, &rn); err != nil {
			fail(w, err)
			return
		}
		var b strings.Builder
		writeRow(&b, id, rn)
		writeJSON(w, b.String())
	})
	mux.HandleFunc("GET /queries", func(w http.ResponseWriter, r *http.Request) {
		n := queryCount(r.URL.Query().Get("n"))
		var b strings.Builder
		b.WriteByte('[')
		for i := 0; i < n; i++ {
			var id, rn int32
			if err := db.QueryRow(r.Context(), selectWorld, randomID()).Scan(&id, &rn); err != nil {
				fail(w, err)
				return
			}
			if i > 0 {
				b.WriteByte(',')
			}
			writeRow(&b, id, rn)
		}
		b.WriteByte(']')
		writeJSON(w, b.String())
	})
	mux.HandleFunc("GET /updates", func(w http.ResponseWriter, r *http.Request) {
		n := queryCount(r.URL.Query().Get("n"))
		ids := distinctIDs(n)
		fresh := make([]int32, n)
		for i := range fresh {
			fresh[i] = randomID()
		}
		ctx := r.Context()
		tx, err := db.Begin(ctx)
		if err != nil {
			fail(w, err)
			return
		}
		defer tx.Rollback(ctx)
		for _, id := range ids {
			var gotID, rn int32
			if err := tx.QueryRow(ctx, selectWorld, id).Scan(&gotID, &rn); err != nil {
				fail(w, err)
				return
			}
		}
		for i, id := range ids {
			if _, err := tx.Exec(ctx, "UPDATE world SET randomnumber = $1 WHERE id = $2", fresh[i], id); err != nil {
				fail(w, err)
				return
			}
		}
		if err := tx.Commit(ctx); err != nil {
			fail(w, err)
			return
		}
		var b strings.Builder
		b.WriteByte('[')
		for i, id := range ids {
			if i > 0 {
				b.WriteByte(',')
			}
			writeRow(&b, id, fresh[i])
		}
		b.WriteByte(']')
		writeJSON(w, b.String())
	})
	mux.HandleFunc("GET /db_wait", func(w http.ResponseWriter, r *http.Request) {
		ms, err := strconv.Atoi(r.URL.Query().Get("ms"))
		if err != nil {
			http.Error(w, "bad ms", http.StatusBadRequest)
			return
		}
		ms = max(1, min(ms, 10000))
		if _, err := db.Exec(r.Context(), "SELECT pg_sleep($1)", float64(ms)/1000); err != nil {
			fail(w, err)
			return
		}
		writeJSON(w, fmt.Sprintf(`{"ms":%d}`, ms))
	})
}
