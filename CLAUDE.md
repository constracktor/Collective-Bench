# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A benchmarking harness comparing HPX's hierarchical collectives (over TCP,
MPI, and LCI parcelports) against an MPI reference implementation (OpenMPI's
`coll/tuned` component), across `broadcast`, `reduce`, `scatter`, `gather`,
`all_gather`, `all_reduce`, and `all_to_all`. The HPX side additionally
sweeps `barrier`, `exclusive_scan`, and `inclusive_scan`, which have no MPI
reference counterpart.

Only the MPI reference benchmark's source lives in this repo
(`mpi/mpi_benchmark.cpp`). The HPX side is a fork
(`https://github.com/constracktor/hpx.git`, branch set by `HPX_VERSION` in
`compile_hpx.sh`) that gets cloned into `hpx/` at build time — its collectives
benchmark source is not here.

## Build

```
./compile_mpi.sh   # -> build/mpi/bin/benchmark_collectives_mpi
./compile_hpx.sh    # clones hpx/ if absent, -> build/hpx/bin/benchmark_collectives_test
```

Both scripts `module load`/`spack load` gcc + openmpi based on `hostname`
(`rostam1`/`medusa*` vs `qbd*`); an unrecognized host aborts the build. This
same host-dispatch block is duplicated in `mpi_tests.sbatch` and
`hpx_tests.sbatch` — keep all four in sync when adding a host or changing
module/spack versions.

`compile_hpx.sh` only rebuilds `hpx/` and reconfigures `build/hpx` if those
directories don't already exist, so pull HPX changes or force a reconfigure by
removing the relevant directory first.

## Running

`./run.sh` submits every (HPX parcelport × node count) + (MPI reference × node
count) combination as separate sbatch jobs, for node counts 1, 2, 4. Logs go
to `logs/output_<jobid>.log` / `logs/error_<jobid>.log`.

To run one sbatch sweep directly, `--nodes=` must be passed to both `sbatch`
(resource allocation) and as a script arg (topology the benchmark uses):

```
sbatch --nodes=4 hpx_tests.sbatch --parcelport=mpi --nodes=4
sbatch --nodes=4 mpi_tests.sbatch --nodes=4
```

`mpi_tests.sbatch` and `hpx_tests.sbatch` each loop over algorithms/arities ×
`test_size` × repeats internally — that's the actual benchmark sweep, not
`run.sh` (which only varies node count and parcelport/reference).

Manual single-run invocations (useful when iterating on the benchmark itself)
are documented in README.md, including the exact `--hpx:ini=...` flags needed
for each parcelport and the `OMPI_MCA_coll_tuned_*` env vars needed to pin an
OpenMPI algorithm.

## MPI benchmark architecture (`mpi/mpi_benchmark.cpp`)

All seven collectives share one harness, `CollectiveBench::run(prepare,
collective, check)`. Each `test_<op>` function only supplies:
- `prepare(i)` — untimed per-iteration buffer setup
- `collective()` — the one timed MPI call
- `check(i)` — correctness validation against the known-expected values

`run()` does the rest identically for every collective: `warmup` untimed
rounds, then `iterations` timed rounds where each round does an
`MPI_Barrier`, times only the collective call, and reduces elapsed time with
`MPI_MAX` to root (so latency reflects the slowest rank, not root's own
completion — meaningful for asymmetric collectives too). Root then appends a
row to the results file via `write_to_file`.

To add a new collective: write a `test_<op>` following this shape and wire the
operation-name string into the dispatch `if/else` chain in `main()`. To change
what's recorded, edit `write_to_file`/`Stats` — the header row and struct stay
in lockstep, so update both.

`validate_algorithm_applicability` rejects OpenMPI's two-process-only tuned
algorithms (`all_gather` algorithm 6, `all_to_all` algorithm 5) unless run
with exactly 2 ranks. `mpi_tests.sbatch` pre-filters the same combinations
before launching `srun` so invalid runs are skipped rather than erroring; the
CI job (`.github/workflows/ci.yml`) explicitly checks that a 4-rank run of
these is rejected with that exact error text, and that a 2-rank run succeeds
— keep the error message and the 2-rank exemption logic consistent across
`mpi_benchmark.cpp` and `mpi_tests.sbatch` if you touch either.

## Output layout and quirks

- MPI: `result/mpi/<num_ranks>/<collective>/<algorithm>/runtimes_<collective>_mpi.txt`
- HPX: `result/hpx/<parcelport>/<num_localities>/<collective>/runtimes_<collective>_<variant>.txt`

Both use the same semicolon-separated columns:
`collective;module;algorithm;nodes;ranks;rpn;size;warmup;iterations;mean;variance;stddev;min;max;median`

Header is written once per file (checked via peek-for-EOF before append), so
downstream tooling parsing these files can assume a single header line.

OpenMPI's tuned component names its `OMPI_MCA_coll_tuned_<name>_algorithm`
suffix differently from this benchmark's `--operation` values —
`broadcast`→`bcast`, `all_gather`→`allgather`, `all_reduce`→`allreduce`,
`all_to_all`→`alltoall` (scatter/reduce/gather match). Both `mpi_tests.sbatch`
and README.md maintain this mapping; an unmapped MCA name is silently ignored
by OpenMPI rather than erroring, so a mismatch here fails silently at the
measurement level, not at build/run time.

The full verified algorithm-ID table (per collective, per OpenMPI 5.x
`coll/tuned`) is in README.md — treat it as the source of truth when adding
new algorithm sweeps, and update both README.md and the comment block atop
`mpi_tests.sbatch` together since they're kept as duplicated references.

## CI (`.github/workflows/ci.yml`)

Builds only the MPI benchmark (no HPX/SLURM in CI). Verifies: the two-process
algorithm rejection (2 ranks accepted, 4 ranks rejected with the expected
error), a smoke run of `broadcast|reduce|scatter|gather` on 2 ranks, and that
each produces a `runtimes_<op>_mpi.txt` file under the new
`result/mpi/<ranks>/<collective>/<algorithm>/` layout. If you change the
output path structure or the two-process error message, update this workflow
too.
