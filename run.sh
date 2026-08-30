#!/usr/bin/env bash
# Submit HPX benchmark jobs: tcp/mpi parcelports at node counts 1, 2, 4, 8, 16;
# lci parcelport only at 1, 2, 4 (its InfiniBand-verbs backend runs out of
# Queue Pairs at larger scale -- see the mpi/lci parcelport crash writeup).
# Does NOT submit the MPI reference benchmark. Each combination becomes one
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
    for pp in tcp mpi; do
        echo "Submitting HPX parcelport=$pp nodes=$nodes"
        sbatch --nodes="$nodes" \
               --partition="$partition" \
               --job-name="hpx_${pp}_n${nodes}" \
               "${ROOT}/hpx_tests.sbatch" \
               --parcelport="$pp" --nodes="$nodes"
    done
done

for nodes in 1 2 4; do
    echo "Submitting HPX parcelport=lci nodes=$nodes"
    sbatch --nodes="$nodes" \
           --partition="$partition" \
           --job-name="hpx_lci_n${nodes}" \
           "${ROOT}/hpx_tests.sbatch" \
           --parcelport=lci --nodes="$nodes"
done
