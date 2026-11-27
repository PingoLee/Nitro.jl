# Environment

- Date: 2026-11-27T02:09:37-03:00
- CPU: AMD Ryzen 5 5500, 12 logical CPUs (6 cores)
- Kernel: Linux 6.8.0-151-generic #151-Ubuntu SMP PREEMPT_DYNAMIC Wed Nov 11 01:28:36 UTC 2026 x86_64
- Governor: powersave; boost: ?
- Clocksource: tsc
- Uptime: up 5 days, 5 hours, 43 minutes (up since 2026-11-21 20:25:50); load before the first block (/proc/loadavg): 3.92 5.15 4.67 1/645 2968054
- Memory: 15858 MiB total, 4687 MiB free, 13692 MiB available; swap used 853 MiB
- Transparent huge pages: enabled always [madvise] never, defrag always defer defer+madvise [madvise] never
- Pinning: the cells and the server on CPUs 0,1,2,3,6,7,8,9 (taskset; 0,1,2 for --threads=2); fairness.sh's load generator on 4,5,10,11. Each column is a fresh process every round.
- Gate: every timed block behind bench/socket/quiet.sh (no other julia, oha or go-server process, load1 < 0.5).

## control: `~/app/julia-618-master/bin/julia-pin-control`

```
ERROR: UndefVarError: `versioninfo` not defined in `Main`
Suggestion: check for spelling errors or missing imports.
Stacktrace:
 [1] top-level scope
   @ none:1
commit 419aba7972bfcb5f18bf8514fe7c86babdb1fa29 (419aba7972)
first depot ~/app/julia-618-master/depot-pin-control
Make.user:
  override CC := /usr/bin/gcc
  override CXX := /usr/bin/g++
  JULIA_CPU_TARGET := generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)
```

## control2: `~/app/julia-618-master/bin/julia-pin-control2`

```
ERROR: UndefVarError: `versioninfo` not defined in `Main`
Suggestion: check for spelling errors or missing imports.
Stacktrace:
 [1] top-level scope
   @ none:1
commit 419aba7972bfcb5f18bf8514fe7c86babdb1fa29 (419aba7972*)
first depot ~/app/julia-618-master/depot-pin-control2
Make.user:
  override CC := /usr/bin/gcc
  override CXX := /usr/bin/g++
  JULIA_CPU_TARGET := generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)
```

## candidate: `~/app/julia-618-master/bin/julia-v5`

```
ERROR: UndefVarError: `versioninfo` not defined in `Main`
Suggestion: check for spelling errors or missing imports.
Stacktrace:
 [1] top-level scope
   @ none:1
commit 28bdb56e6bcda899f9c4ee4a9d4f5feb90fcd799 (28bdb56e6b)
first depot ~/app/julia-618-master/depot-v5
Make.user:
  override CC := /usr/bin/gcc
  override CXX := /usr/bin/g++
  JULIA_CPU_TARGET := generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)
```

## bypass: `~/app/julia-618-master/bin/julia-v5-bypass`

```
ERROR: UndefVarError: `versioninfo` not defined in `Main`
Suggestion: check for spelling errors or missing imports.
Stacktrace:
 [1] top-level scope
   @ none:1
commit 0871cde5b44c9275fda3f856caa946673b2ca9fa (0871cde5b4)
first depot ~/app/julia-618-master/depot-v5-bypass
Make.user:
  override CC := /usr/bin/gcc
  override CXX := /usr/bin/g++
  JULIA_CPU_TARGET := generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)
```

## Package versions

- micro-master: BenchmarkTools 1.8.0, JSON 1.13.4, PrecompileTools 1.3.4
- server-master: HTTP 2.15.3, JSON 1.13.4, PrecompileTools 1.3.4, Reseau 1.7.1
