# Environment

- Date: 2026-11-24T22:32:01-03:00
- CPU: AMD Ryzen 5 5500, 12 logical CPUs (6 cores)
- Kernel: Linux 6.8.0-151-generic #151-Ubuntu SMP PREEMPT_DYNAMIC Wed Nov 11 01:28:36 UTC 2026 x86_64
- Governor: powersave; boost: ?
- Clocksource: tsc
- Uptime: up 3 days, 2 hours, 6 minutes (up since 2026-11-21 20:25:50); load before the first block (/proc/loadavg): 2.71 4.54 4.22 1/635 1832278
- Memory: 15858 MiB total, 4667 MiB free, 13802 MiB available; swap used 896 MiB
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

## candidate: `~/app/julia-618-master/bin/julia-v2`

```
ERROR: UndefVarError: `versioninfo` not defined in `Main`
Suggestion: check for spelling errors or missing imports.
Stacktrace:
 [1] top-level scope
   @ none:1
commit 2caefffc63697b9c0cde695e9fd40ab3bb385dd8 (2caefffc63)
first depot ~/app/julia-618-master/depot-v2
Make.user:
  override CC := /usr/bin/gcc
  override CXX := /usr/bin/g++
  JULIA_CPU_TARGET := generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)
```

## bypass: `~/app/julia-618-master/bin/julia-v2-bypass`

```
ERROR: UndefVarError: `versioninfo` not defined in `Main`
Suggestion: check for spelling errors or missing imports.
Stacktrace:
 [1] top-level scope
   @ none:1
commit 06d2c62c368998a4c2fd0e794d563d215b20fac4 (06d2c62c36)
first depot ~/app/julia-618-master/depot-v2-bypass
Make.user:
  override CC := /usr/bin/gcc
  override CXX := /usr/bin/g++
  JULIA_CPU_TARGET := generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)
```

## timens: `~/app/julia-618-master/bin/julia-v2-timens`

```
ERROR: UndefVarError: `versioninfo` not defined in `Main`
Suggestion: check for spelling errors or missing imports.
Stacktrace:
 [1] top-level scope
   @ none:1
commit 1313112ba5c8e0fd582d777cdc0d3efb0b0bada5 (1313112ba5*)
first depot ~/app/julia-618-master/depot-v2-timens
Make.user:
  override CC := /usr/bin/gcc
  override CXX := /usr/bin/g++
  JULIA_CPU_TARGET := generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)
```

## Package versions

- micro-master: BenchmarkTools 1.8.0, JSON 1.13.4, PrecompileTools 1.3.4
- server-master: HTTP 2.15.3, JSON 1.13.4, PrecompileTools 1.3.4, Reseau 1.7.1
