# Environment

- Date: 2026-11-24T16:31:19-03:00
- CPU: AMD Ryzen 5 5500, 12 logical CPUs (6 cores)
- Kernel: Linux 6.8.0-151-generic #151-Ubuntu SMP PREEMPT_DYNAMIC Wed Nov 11 01:28:36 UTC 2026 x86_64
- Governor: powersave; boost: ?
- Clocksource: tsc
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

## candidate: `~/app/julia-618-master/bin/julia-candidate`

```
ERROR: UndefVarError: `versioninfo` not defined in `Main`
Suggestion: check for spelling errors or missing imports.
Stacktrace:
 [1] top-level scope
   @ none:1
commit 2e8094f8ea880d58dcca9c8338e6b277d228b323 (2e8094f8ea)
first depot ~/app/julia-618-master/depot-candidate
Make.user:
  override CC := /usr/bin/gcc
  override CXX := /usr/bin/g++
  JULIA_CPU_TARGET := generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)
```

## Package versions

- micro-master: BenchmarkTools 1.8.0, JSON 1.13.4, PrecompileTools 1.3.4
- server-master: HTTP 2.15.3, JSON 1.13.4, PrecompileTools 1.3.4, Reseau 1.7.1
