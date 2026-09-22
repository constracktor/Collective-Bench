#!/bin/bash
#SBATCH --job-name=hpx_collectives          # Job name
#SBATCH --nodes=1                 # Overridden at submission time via --nodes=
#SBATCH --ntasks-per-node=32        # Default: 16 tasks per node
#SBATCH --cpus-per-task=1           # 1 core per task (32 tasks/node fits medusa's 40 and buran's 48 cores/node; 2 fits neither)
#SBATCH --time=2-00:00:00           # Time limit (d-hh:mm:ss); scaled for loop=10 (~10x the single-pass runtime), still under buran's 3-day partition cap
#SBATCH --partition=workq         # Specify partition
#SBATCH --output=logs/output_%j.log      # Standard output log
#SBATCH --error=logs/error_%j.log        # Error log file
set -uo pipefail

case "$(hostname)" in
    rostam1*|medusa*|buran*)
        module load gcc/14.2.0
        module load openmpi/5.0.5
        ;;
    qbd*)
        spack load gcc@14.3.0
        spack load openmpi
        export CPATH=$(echo "${CPATH:-}" | tr ':' '\n' | grep -v "intel.*mpi" | tr '\n' ':' | sed 's/:$//')
        ;;
    *)
        echo "ERROR: unknown host $(hostname), cannot load modules" >&2
        exit 1
        ;;
esac

executable="$(pwd)/build/hpx/bin/benchmark_collectives_test"
# Every collective except barrier (size-independent, no payload buffer, so a
# size sweep doesn't apply to it). 65536 is well within the safe range for
# all of these, including all_gather/all_to_all, at up to 16 nodes -- see the
# max-problem-size probe for where those two actually start hurting (in the
# millions of elements, not here).
pairs=("broadcast" "reduce" "all_reduce" "exclusive_scan" "inclusive_scan" "scatter" "gather" "all_gather" "all_to_all")
sizes=(1 4 16 64 256 1024 4096 16384 65536)
export PMIX_MCA_gds=hash

# all_to_all (and similar many-small-message collectives) fan out one
# point-to-point message per peer; above UCX's default rendezvous threshold
# each one triggers its own RDMA memory registration, and at high rank counts
# with several ranks/node sharing one HCA this becomes a registration storm
# (measured: 29s/iteration at 256 ranks vs. 2.1s at 128, slow enough to blow
# through the srun --time limit below). Forcing the eager/copy path instead
# avoids the per-message registration cost; measured 7-8x speedup at 256 ranks.
export UCX_RNDV_THRESH=1048576

parcelport=mpi  # default; override with --parcelport=<tcp|mpi|lci>
nodes=1         # default; override with --nodes=<n>
rpn=32          # default; override with --rpn=<n> (also pass --ntasks-per-node=<n> to sbatch itself)
arities=(-1 2 8)  # default; override with --arities=<comma-separated list, e.g. 4,8,16>
loop=""         # default depends on parcelport (see below); override with --loop=<n>
for arg in "$@"; do
    case "$arg" in
        --parcelport=*) parcelport="${arg#--parcelport=}" ;;
        --nodes=*)      nodes="${arg#--nodes=}" ;;
        --rpn=*)        rpn="${arg#--rpn=}" ;;
        --arities=*)    IFS=',' read -ra arities <<< "${arg#--arities=}" ;;
        --loop=*)       loop="${arg#--loop=}" ;;
        *) echo "WARNING: unknown argument '$arg'" >&2 ;;
    esac
done
# lci repeats each step 2x more than mpi/tcp: its IBV_WC_RETRY_EXC_ERR crashes
# (confirmed scale-dependent -- clean at 128 total ranks, present at 256+ --
# but NOT cleanly tied to any specific collective/size, more likely cumulative
# resource pressure over a long-running job) mean a chunk of steps are lost
# to crashes each pass, so extra repeats help recover more complete coverage.
if [ -z "$loop" ]; then
    if [ "$parcelport" = "lci" ]; then
        loop=20
    else
        loop=10
    fi
fi
echo "Using parcelport: $parcelport, nodes: $nodes, rpn: $rpn, arities: ${arities[*]}, loop: $loop"
iterations=10

# The mpi parcelport requests MPI_THREAD_MULTIPLE by default, which this
# cluster's OpenMPI/UCX can't provide -- it silently falls back to a slower
# transport and can segfault under load. Disabling it costs nothing here
# since every locality only gets one HPX worker thread anyway (-c 1 below),
# so there's no concurrent access to serialize. Harmless no-op for tcp/lci.

# The lci parcelport's ibv backend opens one QP per remote rank per LCI
# device, fully connected. HPX's own lci parcelport ships with a default of
# 2 devices (hpx.parcel.lci.ndevices=2), and LCI's runtime additionally
# opens its own internal "default device" that HPX never actually uses
# (LCI_ATTR_ALLOC_DEFAULT_DEVICE, default on) -- so by default every process
# builds 3 separate full connection meshes instead of 1. The IB QPs run out
# at ~485-507 per process (a firmware/resource ceiling, not a config value),
# so with the default 3x multiplier that's hit around 8 nodes x 32 ranks
# (256 total ranks -> ~500-750 QPs/process needed). Disabling the internal
# default device and setting ndevices=1 drops this back to 1x, i.e. one QP
# per remote rank as expected -- verified working at 8 nodes (256 ranks).
# Harmless no-op for tcp/mpi.
export LCI_ATTR_ALLOC_DEFAULT_DEVICE=0

# Separately: lci uses one shared receive queue (SRQ) per device, fixed at
# 4096 slots regardless of peer count (LCI_BACKEND_MAX_RECVS_DEFAULT). That's
# enough per-peer buffering at ~128 ranks but not at 256+, where receivers
# start NAKing (RNR) under real collective traffic; since our own iteration
# times balloon at scale (2.1s/iter at 128 ranks vs 15-65s/iter at 256+,
# measured for all_gather/all_to_all) this routinely outlasts the HCA's
# ~7.5s retry budget and the sender gives up with IBV_WC_RETRY_EXC_ERR
# ("transport retry counter exceeded"). Confirmed via direct IB fabric
# diagnostics (perfquery/ib_send_bw) that this is NOT bad hardware -- every
# node's hw_counters show nonzero retries, and raw RDMA traffic between
# "suspect" nodes ran at full line rate with zero errors. Requesting a much
# higher value here is safe: LCI clamps it to the HCA's actual max_srq_wr
# automatically (with a warning) if it's too high. Harmless no-op for
# tcp/mpi.
export LCI_ATTR_NET_MAX_RECVS=65536

# Per-step time limit, scaled to test_size. The default (2 min) covers every
# size up to 4096 comfortably. 16384/65536 are genuinely slow at high rank
# counts for the many-small-message collectives (all_gather/all_to_all) --
# measured at 256 ranks: ~15.6s/iteration (16384) and ~65.2s/iteration
# (65536), i.e. ~4.2min and ~17.4min for the full warmup+iterations+cooldown
# run. This is real bandwidth-bound cost (confirmed linear-ish scaling with
# size), not a hang -- give it the wall-clock time it legitimately needs
# instead of killing it partway through.
step_time_for_size() {
    case "$1" in
        65536) echo "0:20:00" ;;
        16384) echo "0:08:00" ;;
        *)     echo "0:02:00" ;;
    esac
}

execute_task() {
  local task_name=$1
  shift
  local sizes=("$@")

  for arity in "${arities[@]}"; do
    for test_size in "${sizes[@]}"; do
        for (( j=0; j<loop; j++ )); do
            srun --mpi=pmix --time="$(step_time_for_size "$test_size")" --cpu-bind=none \
                -N "$nodes" --ntasks-per-node "$rpn" -c 1 \
                "$executable" --arity="$arity" --lpn="$rpn" --operation="$task_name" \
                --test_size="$test_size" --iterations="$iterations" \
                --warmup_iterations=3 --cooldown_iterations=3 \
                --hpx:ini=hpx.parcel.tcp.enable=0 \
                --hpx:ini=hpx.parcel.mpi.enable=0 \
                --hpx:ini=hpx.parcel.lci.enable=0 \
                --hpx:ini=hpx.parcel."$parcelport".enable=1 \
                --hpx:ini=hpx.parcel.bootstrap="$parcelport" \
                --hpx:ini=hpx.parcel."$parcelport".priority=1000 \
                --hpx:ini=hpx.parcel.mpi.multithreaded=0 \
                --hpx:ini=hpx.parcel.lci.ndevices=1
        done
    done
  done
}

for operation in "${pairs[@]}"; do
  execute_task "$operation" "${sizes[@]}"
done
