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
# Collectives split by memory-scaling class (see max-problem-size probe):
# broadcast/reduce/all_reduce/scan/scatter/gather are O(1)-per-rank or
# root-only O(ranks), so they tolerate much larger sizes than all_gather/
# all_to_all, which hold O(ranks * size) on every rank. barrier has no
# payload buffer at all, so it doesn't need a size sweep and is omitted here.
large_tolerant_pairs=("broadcast" "reduce" "all_reduce" "exclusive_scan" "inclusive_scan" "scatter" "gather")
size_limited_pairs=("all_gather" "all_to_all")
export PMIX_MCA_gds=hash

# Parcelport fixed to mpi for now -- tcp/lci already have full standard-size
# coverage from the earlier sweep; only mpi needs these new large sizes.
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

execute_task() {
  local task_name=$1
  shift
  local sizes=("$@")

  for arity in -1 2; do
    for rpn in 32; do
        for test_size in "${sizes[@]}"; do
            for (( j=0; j<loop; j++ )); do
                srun --mpi=pmix --time=0:02:00 --cpu-bind=none \
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

for operation in "${large_tolerant_pairs[@]}"; do
  execute_task "$operation" 65536 262144 1048576 4194304 16777216
done
for operation in "${size_limited_pairs[@]}"; do
  execute_task "$operation" 65536 262144
done
