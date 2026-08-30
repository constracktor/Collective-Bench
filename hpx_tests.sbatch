#!/bin/bash
#SBATCH --job-name=hpx_collectives          # Job name
#SBATCH --nodes=1                 # Overridden at submission time via --nodes=
#SBATCH --ntasks-per-node=32        # Default: 16 tasks per node
#SBATCH --cpus-per-task=1           # 1 core per task (32 tasks/node fits medusa's 40 and buran's 48 cores/node; 2 fits neither)
#SBATCH --time=72:00:00             # Time limit (hh:mm:ss)
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
pairs=("broadcast" "reduce" "scatter" "gather" "all_gather" "all_reduce" "all_to_all" "barrier" "exclusive_scan" "inclusive_scan")
export PMIX_MCA_gds=hash

# Parse command-line arguments
parcelport=tcp  # default; override with --parcelport=<tcp|mpi|lci>
nodes=1         # default; override with --nodes=<n>
for arg in "$@"; do
    case "$arg" in
        --parcelport=*) parcelport="${arg#--parcelport=}" ;;
        --nodes=*)      nodes="${arg#--nodes=}" ;;
        *) echo "WARNING: unknown argument '$arg'" >&2 ;;
    esac
done
echo "Using parcelport: $parcelport, nodes: $nodes"
iterations=10
loop=5

# The mpi parcelport requests MPI_THREAD_MULTIPLE by default, which this
# cluster's OpenMPI/UCX can't provide -- it silently falls back to a slower
# transport and can segfault under load. Disabling it costs nothing here
# since every locality only gets one HPX worker thread anyway (-c 1 below),
# so there's no concurrent access to serialize. Harmless no-op for tcp/lci.

execute_task() {
  local task_name=$1

  for arity in -1 2; do
    for rpn in 32; do
        for test_size in 1 4 16 64 256 1024 4096 16384; do
            for (( j=0; j<loop; j++ )); do
                srun --mpi=pmix --time=0:02:00 --cpu-bind=none \
                    -N "$nodes" --ntasks-per-node "$rpn" -c 1 \
                    "$executable" --arity="$arity" --lpn="$rpn" --operation="$task_name" \
                    --test_size="$test_size" --iterations="$iterations" \
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
  execute_task "$operation"
done
