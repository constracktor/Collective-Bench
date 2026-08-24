#!/bin/bash
#SBATCH --job-name=mpi_collectives           # Job name
#SBATCH --nodes=1                 # Overridden at submission time via --nodes=
#SBATCH --ntasks-per-node=32       # Default: 16 tasks per node
#SBATCH --cpus-per-task=2           # 2 cores per task
#SBATCH --time=72:00:00             # Time limit (hh:mm:ss)
#SBATCH --partition=workq         # Specify partition
#SBATCH --output=logs/output_%j.log      # Standard output log
#SBATCH --error=logs/error_%j.log        # Error log file
set -uo pipefail

case "$(hostname)" in
    rostam1|medusa*)
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

# Algorithm IDs for OpenMPI 5.x coll/tuned component
# (OMPI_MCA_coll_tuned_use_dynamic_rules=1 must be set for these to apply).
# 0 = ignore / let OpenMPI auto-select.
# Source: ompi/mca/coll/tuned/coll_tuned_decision_fixed.c (v5.0.5)
#
# broadcast  (mca: bcast)
#   1 basic_linear  2 chain  3 pipeline  4 split_binary_tree
#   5 binary_tree   6 binomial  7 knomial  8 scatter_allgather
#   9 scatter_allgather_ring
#
# reduce
#   1 linear  2 chain  3 pipeline  4 binary
#   5 binomial  6 in-order_binary  7 rabenseifner
#
# scatter
#   1 basic_linear  2 binomial  3 linear_nb
#
# gather
#   1 basic_linear  2 binomial  3 linear_sync
#
# all_gather  (mca: allgather)
#   1 linear  2 bruck  3 recursive_doubling
#   4 ring  5 neighbor  6 two_proc
#
# all_reduce  (mca: allreduce)
#   1 basic_linear  2 nonoverlapping  3 recursive_doubling
#   4 ring  5 segmented_ring  6 rabenseifner
#
# all_to_all  (mca: alltoall)
#   1 linear  2 pairwise  3 modified_bruck  4 linear_sync  5 two_proc

# "<operation> <num_algorithms>" — loops algorithm IDs 0..(n-1)
pairs=("broadcast 10" "reduce 8" "scatter 4" "gather 4" "all_gather 7" "all_reduce 7" "all_to_all 6")
export PMIX_MCA_gds=hash
partition=workq
iterations=10
loop=5

# Parse command-line arguments
nodes=1  # default; override with --nodes=<n>
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
  # OMPI_MCA_coll_tuned_<op>_algorithm parameter. Map our operation names to
  # them so the algorithm selection actually takes effect; an unmapped name is
  # silently ignored by OpenMPI.
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
        for test_size in 1 4 16 64 256 1024 4096 16384; do
            for (( j=0; j<loop; j++ )); do
                srun --mpi=pmix --time=0:10:00 \
                    --export=ALL,OMPI_MCA_coll_tuned_use_dynamic_rules=1,OMPI_MCA_coll_tuned_${mca_op}_algorithm=$i \
                    -N "$nodes" --ntasks-per-node "$rpn" -c 2 \
                    "$executable" --algorithm="$i" --rpn="$rpn" --operation="$task_name" \
                    --test_size="$test_size" --iterations="$iterations" \
                    --warmup_iterations=3
            done
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
