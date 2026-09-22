#!/bin/bash
#SBATCH --job-name=mpi_collectives_quick     # Job name
#SBATCH --nodes=2                 # Fixed at 2 nodes; override with --nodes=
#SBATCH --ntasks-per-node=32       # Default: 32 tasks per node
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

executable="$(pwd)/build/mpi/bin/benchmark_collectives_mpi"

# Quick smoke sweep: every algorithm for every collective, at a single
# representative problem size, minimal iterations, no repeats -- meant to
# finish in about a minute on 2 nodes, not to produce statistically
# meaningful timings. For the full sweep (all problem sizes, 5 repeats) use
# mpi_tests.sbatch instead. Algorithm IDs: see mpi_tests.sbatch or README.md.
pairs=("broadcast 10" "reduce 8" "scatter 4" "gather 4" "all_gather 7" "all_reduce 7" "all_to_all 6")
export PMIX_MCA_gds=hash
iterations=3
warmup=1
cooldown=1
test_sizes=(256)

# Parse command-line arguments
nodes=2  # default; override with --nodes=<n>
for arg in "$@"; do
    case "$arg" in
        --nodes=*) nodes="${arg#--nodes=}" ;;
        *) echo "WARNING: unknown argument '$arg'" >&2 ;;
    esac
done
echo "Using nodes: $nodes"

execute_task() {
  local task_name=$1
  local count=$2

  # OpenMPI's tuned component uses its own (un-underscored) names for the
  # OMPI_MCA_coll_tuned_<op>_algorithm parameter. See mpi_tests.sbatch.
  local mca_op
  case "$task_name" in
    broadcast)  mca_op="bcast" ;;
    all_gather) mca_op="allgather" ;;
    all_reduce) mca_op="allreduce" ;;
    all_to_all) mca_op="alltoall" ;;
    *)          mca_op="$task_name" ;;
  esac

  for ((i=0; i<count; i++)); do
    for rpn in 32; do
        if [[ $((nodes * rpn)) -ne 2 &&
              ("$task_name:$i" == "all_gather:6" ||
               "$task_name:$i" == "all_to_all:5") ]]; then
            echo "Skipping $task_name algorithm $i: two_proc requires exactly 2 ranks"
            continue
        fi
        for test_size in "${test_sizes[@]}"; do
            srun --mpi=pmix --time=0:02:00 --cpu-bind=none \
                --export=ALL,OMPI_MCA_coll_tuned_use_dynamic_rules=1,OMPI_MCA_coll_tuned_${mca_op}_algorithm=$i \
                -N "$nodes" --ntasks-per-node "$rpn" -c 1 \
                "$executable" --algorithm="$i" --rpn="$rpn" --operation="$task_name" \
                --test_size="$test_size" --iterations="$iterations" \
                --warmup_iterations="$warmup" --cooldown_iterations="$cooldown"
        done
    done
  done
}

for pair in "${pairs[@]}"; do
  # Intentional word splitting: "<task> <count>" into positional parameters.
  # shellcheck disable=SC2086
  set -- $pair
  execute_task "$1" "$2"
done
