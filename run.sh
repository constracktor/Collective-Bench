#!/usr/bin/env bash
# Submit HPX (all three parcelports) and MPI reference benchmark jobs for
# node counts 1, 2, 4 (powers of 2).  Each combination becomes one sbatch job.
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

for nodes in 1 2 4; do
    for pp in mpi tcp lci; do
        echo "Submitting HPX parcelport=$pp nodes=$nodes"
        sbatch --nodes="$nodes" \
               --partition="$partition" \
               --job-name="hpx_${pp}_n${nodes}" \
               "${ROOT}/hpx_tests.sbatch" \
               --parcelport="$pp" --nodes="$nodes"
    done

    echo "Submitting MPI reference nodes=$nodes"
    sbatch --nodes="$nodes" \
           --partition="$partition" \
           --job-name="mpi_ref_n${nodes}" \
           "${ROOT}/mpi_tests.sbatch" \
           --nodes="$nodes"
done
