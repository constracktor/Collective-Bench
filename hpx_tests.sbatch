#!/bin/bash
#SBATCH --job-name=hpx_collectives          # Job name
#SBATCH --nodes=1                 # Overridden at submission time via --nodes=
#SBATCH --ntasks-per-node=32        # Default: 16 tasks per node
#SBATCH --cpus-per-task=1           # 1 core per task (32 tasks/node fits medusa's 40 and buran's 48 cores/node; 2 fits neither)
#SBATCH --time=04:00:00             # Time limit (hh:mm:ss); generous vs observed runtimes but short enough for backfill scheduling to actually use idle nodes
#SBATCH --partition=workq         # Specify partition
#SBATCH --output=logs/output_%j.log      # Standard output log
#SBATCH --error=logs/error_%j.log        # Error log file
set -uo pipefail

case "$(hostname)" in
    rostam1|medusa*|buran*)
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

# Parcelport fixed to mpi for now -- tcp/lci support isn't wired back into
# this sweep yet.
parcelport=mpi
nodes=1         # default; override with --nodes=<n>
for arg in "$@"; do
    case "$arg" in
        --nodes=*) nodes="${arg#--nodes=}" ;;
        *) echo "WARNING: unknown argument '$arg'" >&2 ;;
    esac
done
echo "Using parcelport: $parcelport, nodes: $nodes"
iterations=10
loop=1

# The mpi parcelport requests MPI_THREAD_MULTIPLE by default, which this
# cluster's OpenMPI/UCX can't provide -- it silently falls back to a slower
# transport and can segfault under load. Disabling it costs nothing here
# since every locality only gets one HPX worker thread anyway (-c 1 below),
# so there's no concurrent access to serialize.

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

  for arity in -1 2; do
    for rpn in 32; do
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
                    --hpx:ini=hpx.parcel.mpi.multithreaded=0
            done
        done
    done
  done
}

for operation in "${pairs[@]}"; do
  execute_task "$operation" "${sizes[@]}"
done
