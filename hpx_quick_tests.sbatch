#!/bin/bash
#SBATCH --job-name=hpx_collectives_quick    # Job name
#SBATCH --nodes=2                 # Fixed at 2 nodes; override with --nodes=
#SBATCH --ntasks-per-node=32        # Default: 32 tasks per node
#SBATCH --cpus-per-task=1           # 1 core per task (fits medusa's 40 and buran's 48 cores/node)
#SBATCH --time=00:10:00             # Time limit (hh:mm:ss)
#SBATCH --partition=workq         # Specify partition (override with sbatch --partition=medusa|buran)
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
        spack load openmpi@5.0.10
        export CPATH=$(echo "${CPATH:-}" | tr ':' '\n' | grep -v "intel.*mpi" | tr '\n' ':' | sed 's/:$//')
        ;;
    *)
        echo "ERROR: unknown host $(hostname), cannot load modules" >&2
        exit 1
        ;;
esac

executable="$(pwd)/build/hpx/bin/benchmark_collectives_test"
pairs=("broadcast" "reduce" "scatter" "gather" "all_gather" "all_reduce" "all_to_all")
export PMIX_MCA_gds=hash

# Quick smoke sweep: every operation across every arity, at a single
# representative problem size, minimal iterations, no repeats -- meant to
# finish in about a minute on 2 nodes. For the full sweep (all problem sizes,
# 5 repeats) use hpx_tests.sbatch instead.
parcelport=tcp  # default; override with --parcelport=<tcp|mpi|lci>
nodes=2         # default; override with --nodes=<n>
for arg in "$@"; do
    case "$arg" in
        --parcelport=*) parcelport="${arg#--parcelport=}" ;;
        --nodes=*)      nodes="${arg#--nodes=}" ;;
        *) echo "WARNING: unknown argument '$arg'" >&2 ;;
    esac
done
echo "Using parcelport: $parcelport, nodes: $nodes"
iterations=3
test_sizes=(256)

execute_task() {
  local task_name=$1

  for arity in -1 2 4 8; do
    for rpn in 32; do
        for test_size in "${test_sizes[@]}"; do
            srun --mpi=pmix --time=0:02:00 --cpu-bind=none \
                -N "$nodes" --ntasks-per-node "$rpn" -c 1 \
                "$executable" --arity="$arity" --lpn="$rpn" --operation="$task_name" \
                --test_size="$test_size" --iterations="$iterations" \
                --hpx:ini=hpx.parcel.tcp.enable=0 \
                --hpx:ini=hpx.parcel.mpi.enable=0 \
                --hpx:ini=hpx.parcel.lci.enable=0 \
                --hpx:ini=hpx.parcel."$parcelport".enable=1 \
                --hpx:ini=hpx.parcel.bootstrap="$parcelport" \
                --hpx:ini=hpx.parcel."$parcelport".priority=1000
        done
    done
  done
}

for operation in "${pairs[@]}"; do
  execute_task "$operation"
done
