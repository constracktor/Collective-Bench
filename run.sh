#!/usr/bin/env bash
# Submit HPX benchmark jobs (new large-size sweep) at node counts 1, 2, 4, 8,
# 16. hpx_tests.sbatch is currently fixed to the mpi parcelport only -- tcp/
# lci already have full standard-size coverage from the earlier sweep, and
# tcp/lci support for these new large sizes hasn't been added back yet.
# Does NOT submit the MPI reference benchmark. Each node count becomes one
# sbatch job.
# Usage: ./run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Select the SLURM partition for this cluster. The scripts' own #SBATCH
# headers default to "workq" (qbd), which doesn't exist on rostam/medusa/buran
# -- override it here so submission works without editing the scripts.
case "$(hostname)" in
    rostam1|medusa*)
        partition=medusa
        ;;
    buran*)
        partition=buran
        ;;
    qbd*)
        partition=workq
        ;;
    *)
        echo "ERROR: unknown host $(hostname), cannot select SLURM partition" >&2
        exit 1
        ;;
esac

for nodes in 1 2 4 8 16; do
    echo "Submitting HPX parcelport=mpi nodes=$nodes"
    sbatch --nodes="$nodes" \
           --partition="$partition" \
           --job-name="hpx_mpi_n${nodes}" \
           "${ROOT}/hpx_tests.sbatch" \
           --nodes="$nodes"
done
