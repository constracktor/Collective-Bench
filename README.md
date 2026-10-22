# Collective-Bench

A benchmarking harness that compares HPX's hierarchical collectives, over the
TCP, MPI and LCI parcelports, against an MPI reference implementation
(OpenMPI 5.0.x) on SLURM clusters.

Both benchmarks support `broadcast`, `reduce`, `scatter`, `gather`,
`all_gather`, `all_reduce`, `all_to_all`, `inclusive_scan` (`MPI_Scan`), and
`exclusive_scan` (`MPI_Exscan`); the HPX benchmark additionally supports
`barrier` (no MPI reference equivalent). Both validate correctness on every
iteration and append per-run statistics to a semicolon-separated file under
`result/` (one header per file).

Only the MPI reference benchmark's source lives in this repo. The HPX
benchmark (`libs/full/collectives/tests/performance/benchmark_collectives.cpp`)
is part of upstream HPX and is built from a clone made by `compile_hpx.sh`.

## Repository layout

| Path | Purpose |
| --- | --- |
| `compile_hpx.sh` | Clone upstream HPX (`STEllAR-GROUP/hpx`, `master`) and build the collectives benchmark target. |
| `compile_mpi.sh` | Build the MPI reference benchmark via CMake. |
| `mpi/mpi_benchmark.cpp` | MPI reference benchmark source. |
| `mpi/CMakeLists.txt` | CMake build for the MPI benchmark. |
| `run.sh` | Submit the full HPX sweep (parcelports × node counts) in one shot. |
| `hpx_tests.sbatch` | SLURM batch sweep for HPX (parcelport and node count as CLI args). |
| `mpi_tests.sbatch` | SLURM batch sweep for MPI (node count as CLI arg); currently algorithm 0 (OpenMPI's automatic choice) only. |
| `hpx_quick_tests.sbatch` | Quick HPX smoke sweep: all operations × arities, one problem size, 2 nodes, ~1 minute. |
| `mpi_quick_tests.sbatch` | Quick MPI smoke sweep: all algorithms, one problem size, 2 nodes, ~1 minute. |
| `.github/workflows/ci.yml` | CI: builds and smoke-tests the MPI benchmark. |
| `LICENSE` | Boost Software License 1.0. |
| `logs/`, `result/` | Job logs and benchmark output (git-ignored). |

## Requirements

- `gcc/14.2.0` and `openmpi/5.0.5` on rostam/medusa/buran (loaded via `module load`)
- `gcc@14.3.0` and `openmpi@5.0.10` on qbd (loaded via `spack load`)
- CMake ≥ 3.16
- [`cxxopts`](https://github.com/jarro2783/cxxopts) — used by the MPI benchmark.
  Found via `find_package` if installed, otherwise fetched automatically during
  the CMake configure step.

The build and sbatch scripts pick modules by `hostname` and abort on an
unknown host.

## Quick start

```
./compile_mpi.sh && ./compile_hpx.sh      # build both benchmarks
./run.sh                                  # submit the HPX sweep
sbatch --nodes=4 mpi_tests.sbatch --nodes=4   # submit one MPI sweep (add --partition=...)
```

## How to compile

HPX benchmark: `./compile_hpx.sh`
→ produces `build/hpx/bin/benchmark_collectives_test`

MPI benchmark: `./compile_mpi.sh`
→ produces `build/mpi/bin/benchmark_collectives_mpi`

`compile_hpx.sh` only clones into `hpx/` and configures `build/hpx/` if those
directories don't exist yet. To pick up a newer HPX `master` (or switch an
existing clone to upstream), update or remove `hpx/` and remove `build/hpx/`
before rerunning it.

## How to run

### All HPX jobs at once

```
./run.sh
```

Submits one `hpx_tests.sbatch` job per (parcelport, node count): `mpi` and
`tcp` at 1, 2, 4, 8, 16 nodes, `lci` at 1, 2, 4, 8 nodes (see the comment in
`run.sh` for why LCI is capped). The SLURM partition is chosen from the
hostname (rostam1/buran → `buran`, medusa → `medusa`, qbd → `workq`). `run.sh`
does **not** submit the MPI reference sweep; submit `mpi_tests.sbatch`
separately (see below). Logs land in `logs/output_<jobid>.log` and
`logs/error_<jobid>.log`.

### Quick smoke sweep

```
sbatch --partition=buran mpi_quick_tests.sbatch
sbatch --partition=buran hpx_quick_tests.sbatch --parcelport=tcp
```

At a single representative problem size (`test_size=256`) with minimal
iterations and no repeats, fixed at 2 nodes × 32 ranks. The HPX script runs
every operation (including `barrier`) at arities -1 and 2; the MPI script runs
every algorithm ID of all nine collectives. Meant to finish in
about a minute and sanity-check that every combination still runs and
validates correctly — not to produce statistically meaningful timings. Use
`mpi_tests.sbatch`/`hpx_tests.sbatch` for the full sweep.

### Manually

HPX benchmark:

```
module load gcc/14.2.0
srun -p medusa -N 2 --ntasks-per-node 2 -c 1 \
    build/hpx/bin/benchmark_collectives_test \
    --arity=2 --lpn=2 --operation=reduce --test_size=1024 --iterations=10 \
    --hpx:ini=hpx.parcel.tcp.enable=1 \
    --hpx:ini=hpx.parcel.bootstrap=tcp \
    --hpx:ini=hpx.parcel.tcp.priority=1000
```

The `mpi` parcelport additionally needs
`--hpx:ini=hpx.parcel.mpi.multithreaded=0` — this cluster's OpenMPI/UCX
doesn't support the `MPI_THREAD_MULTIPLE` level HPX requests by default,
which otherwise silently falls back to a slower transport and can segfault
under load. Disabling it costs nothing here since every locality only gets
one HPX worker thread anyway (`-c 1`), so there's no concurrent MPI access to
serialize. `hpx_tests.sbatch`/`hpx_quick_tests.sbatch` already set this. For
`lci`, `hpx_tests.sbatch` also sets `--hpx:ini=hpx.parcel.lci.ndevices=1`,
`LCI_ATTR_ALLOC_DEFAULT_DEVICE=0` and `LCI_ATTR_NET_MAX_RECVS=65536` (needed
at 256+ ranks; see the comments in the script).

MPI benchmark:

```
srun --mpi=pmix --cpu-bind=core \
    --export=ALL,OMPI_MCA_coll_tuned_use_dynamic_rules=1,OMPI_MCA_coll_tuned_reduce_algorithm=1,OMPI_MCA_mpi_yield_when_idle=0 \
    -p medusa -N 2 --ntasks-per-node 2 -c 1 \
    build/mpi/bin/benchmark_collectives_mpi \
    --algorithm=1 --rpn=2 --operation=reduce --test_size=1024 --iterations=10
```

Options: `--operation`, `--test_size` (ints per rank), `--iterations`,
`--warmup_iterations` (default 3), `--cooldown_iterations` (default 3, untimed
rounds after the timed ones), `--rpn` (ranks per node, used for the `nodes`
column), `--algorithm` (recorded in the output path/column; the benchmark
warns if it doesn't match the `OMPI_MCA_coll_tuned_*` env vars), and
`--module` (label for the `module` column, default `tuned`).

Note: OpenMPI's tuned component uses `bcast`/`allgather`/`allreduce`/`alltoall`/`scan`/`exscan`
as the MCA parameter suffix even though the benchmark uses `broadcast`/`all_gather`/…/`inclusive_scan`/`exclusive_scan`
as operation names. An unmapped MCA name is silently ignored by OpenMPI.

### Sbatch scripts

Both scripts accept CLI arguments to override defaults:

```
sbatch --nodes=4 --partition=medusa hpx_tests.sbatch --parcelport=mpi --nodes=4
sbatch --nodes=4 --partition=medusa mpi_tests.sbatch --nodes=4
```

The `--nodes=` flag must be passed both to `sbatch` (for resource allocation)
and as a script argument (so the benchmark knows the topology). Both scripts'
`#SBATCH --partition=workq` default only applies to qbd; on medusa pass
`--partition=medusa`, on rostam1/buran pass `--partition=buran`. `run.sh`
handles both the `--nodes=` duplication and the partition selection
automatically for the HPX jobs.

## Sweep details

Both full sweeps use 32 ranks/localities per node, one core each, and sizes
1 4 16 64 256 1024 4096 16384 65536 (ints per rank), with 3 warmup and 3
cooldown iterations per run.

`hpx_tests.sbatch`: every collective except `barrier`, arities -1, 2, 8
(`--arities=4,8,16` to override), 10 timed iterations per run, each run
repeated 10× (20× for `lci`; `--loop=<n>` to override). `--rpn=<n>` changes
localities per node (also pass `--ntasks-per-node=<n>` to `sbatch`).

`mpi_tests.sbatch`: all nine collectives, algorithm 0 only (OpenMPI's
automatic choice), 1000 timed iterations per run, each run repeated 10×.
Runs use `--cpu-bind=core` and `OMPI_MCA_mpi_yield_when_idle=0`; without them
waiting ranks can be migrated or fall back to `sched_yield()` polling, which
at 8+ nodes compounds into a sustained multi-millisecond slowdown (reduce,
16 nodes, size 4: median 4.0 ms without them, 17 µs with them). To sweep specific
algorithms, raise the counts in the script's `pairs` array (it loops IDs
`0..count-1`) using the table below.

### MPI timing

Each timed iteration starts from an `MPI_Barrier` and times only the
collective call. Per-iteration elapsed times stay local during the loop and
are reduced once with `MPI_MAX` onto root after the loop, so each recorded
iteration is the **slowest rank's latency**. Setting
`MPIBENCH_DUMP_ITERS=<dir>` additionally dumps every rank's raw,
unreduced per-iteration times to `<dir>/rank_<n>.csv` (diagnostic only, off by
default; the directory must exist).

### MPI algorithm IDs (OpenMPI 5.x coll/tuned, verified against v5.0.5 and v5.0.10)

`OMPI_MCA_coll_tuned_use_dynamic_rules=1` must be set for these to apply.
Algorithm `0` = ignore (OpenMPI auto-selects).

| Collective | MCA suffix | IDs |
| --- | --- | --- |
| broadcast | `bcast` | 1 basic_linear, 2 chain, 3 pipeline, 4 split_binary_tree, 5 binary_tree, 6 binomial, 7 knomial, 8 scatter_allgather, 9 scatter_allgather_ring |
| reduce | `reduce` | 1 linear, 2 chain, 3 pipeline, 4 binary, 5 binomial, 6 in-order_binary, 7 rabenseifner |
| scatter | `scatter` | 1 basic_linear, 2 binomial, 3 linear_nb |
| gather | `gather` | 1 basic_linear, 2 binomial, 3 linear_sync |
| all_gather | `allgather` | 1 linear, 2 bruck, 3 recursive_doubling, 4 ring, 5 neighbor, 6 two_proc (exactly 2 ranks) |
| all_reduce | `allreduce` | 1 basic_linear, 2 nonoverlapping, 3 recursive_doubling, 4 ring, 5 segmented_ring, 6 rabenseifner |
| all_to_all | `alltoall` | 1 linear, 2 pairwise, 3 modified_bruck, 4 linear_sync, 5 two_proc (exactly 2 ranks) |
| inclusive_scan | `scan` | 1 linear, 2 recursive_doubling |
| exclusive_scan | `exscan` | 1 linear, 2 recursive_doubling |

`mpi_tests.sbatch` skips the two-process algorithms unless the job has exactly
two ranks. The MPI benchmark rejects the same invalid combinations when run
manually.

### OpenMPI's HAN component

OpenMPI 5.x ships the hierarchical `coll/han` component with default priority
35, above `coll/tuned`'s 30. On multi-node runs HAN can therefore serve
`bcast`, `reduce`, `allreduce`, `allgather`, `gather` and `scatter`, in which
case the `OMPI_MCA_coll_tuned_<op>_algorithm` settings above do not apply as
intended. Check which component is used with `OMPI_MCA_coll_base_verbose=9`,
which logs `coll:han:get_algorithm` lines when HAN is selected. The scripts in
this repo do not change the priorities, so the default sweep measures
OpenMPI's default behavior.

For a tuned-only baseline, disable HAN (and UCC, if your OpenMPI is built with
it) by adding the following to the `srun --export=` list:

```
OMPI_MCA_coll_han_priority=0,OMPI_MCA_coll_ucc_priority=0
```

Results from the two configurations are not comparable; keep them in separate
result trees.

### LCI at 500+ localities

Out of the box, HPX's LCI parcelport failed with roughly 500 or more
localities, for three independent reasons. `patches/hpx-lci-scale.patch`
(applied by `compile_hpx.sh` after cloning) fixes them inside HPX; the
sweep scripts no longer need any `LCI_ATTR_*` environment variables for this.

- **Queue pair resources.** LCI opens one InfiniBand queue pair per remote
  locality and device and, by default, one thread domain per queue pair.
  Those run out at ~480-500 per process (`ibv_alloc_td() failed`, then
  `Couldn't create QP`). The parcelport now disables LCI's unused default
  device, switches to shared queue locks above 128 connections per process,
  scales the shared receive queue with the number of localities, and reduces
  `hpx.parcel.lci.ndevices` so a process keeps at most
  `hpx.parcel.lci.max_qps_per_process` (default 256; `0` disables the cap)
  connections. Explicit `LCI_ATTR_*` variables still take precedence.
- **Startup time.** LCI exchanged the queue pair addresses through the PMIx
  key-value store, which moves O(N^3) bytes in total: 31 s at 256 ranks,
  254 s at 384 ranks, and not finishing at 512. HPX now builds LCI with its MPI
  bootstrap backend (`HPX_WITH_LCI_BOOTSTRAP_MPI`, on by default with the MPI
  parcelport; the cmake variable that selects it was misnamed before) and
  patches LCI to use a real `MPI_Alltoall` for the exchange. Override with
  `LCT_PMI_BACKEND=pmix` at runtime. The PMIx path additionally no longer
  calls `PMIx_Commit` once per published key.
- **Patch handling.** Both LCI changes are patch files under `hpx/cmake/patches`
  that HPX's cmake applies to the fetched LCI sources.

## Output

Results are written to:

- HPX: `result/hpx/<parcelport>/<num_localities>/<collective>/runtimes_<collective>_<variant>.txt`
  where `<variant>` is the collective implementation (e.g. `single_use`, `multi_use`, `hierarchical_2`)
- MPI: `result/mpi/<num_ranks>/<collective>/<algorithm>/runtimes_<collective>_mpi.txt`

Both are semicolon-separated with a single header line per file. MPI columns:

```
collective;module;algorithm;nodes;ranks;rpn;size;warmup;iterations;mean;variance;stddev;min;max;median
```

HPX columns (as written by the upstream HPX benchmark):

```
collective;type;arity;nodes;localities;lpn;threads;size;warmup;cooldown;iterations;mean;variance;stddev;min;max;median
```

The MPI `module` column is just the `--module` label (default `tuned`, which
the scripts never override); it does not reflect which coll component
actually ran (see the HAN caveat above).

## CI

`.github/workflows/ci.yml` builds only the MPI benchmark (no HPX, no SLURM),
checks that the two-process algorithms are accepted on 2 ranks and rejected on
4 with the expected error, smoke-runs `broadcast`, `reduce`, `scatter`,
`gather`, `inclusive_scan` and `exclusive_scan` on 2 ranks, and checks that
each wrote its `runtimes_<op>_mpi.txt`.

## License

Distributed under the Boost Software License, Version 1.0 (see [`LICENSE`](LICENSE)).

## Contact

alexander.strack@ipvs.uni-stuttgart.de
