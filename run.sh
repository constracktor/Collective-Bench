#!/usr/bin/env bash
# Submit HPX benchmark jobs at node counts 1, 2, 4, 8, 16 for the mpi, tcp and
# lci parcelports. hpx_tests.sbatch sweeps every
# collective except barrier, sizes 1-65536, arities -1, 2 and 8.
#
# lci used to be capped at 8 nodes (256 ranks): at ~500 ranks the InfiniBand
# queue pair resources ran out and LCI's PMIx bootstrap took minutes to hang.
# Both are fixed inside HPX by patches/hpx-lci-scale.patch (see README.md,
# "LCI at 500+ localities"), so lci now runs at the same node counts as the
# other parcelports.
#
# Does NOT submit the MPI reference benchmark. Each (parcelport, node count)
# becomes one sbatch job.
# Usage: ./run.sh [parcelport...]   (default: mpi tcp lci)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
parcelports=("$@")
[[ ${#parcelports[@]} -eq 0 ]] && parcelports=(mpi tcp lci)

# Select the SLURM partition for this cluster. The scripts' own #SBATCH
# headers default to "workq" (qbd), which doesn't exist on rostam/medusa/buran
# -- override it here so submission works without editing the scripts.
#
# rostam1 -> buran (not medusa): every QP-ceiling/PMIx-bootstrap fix in this
# sweep was diagnosed and verified on buran's specific hardware, and rostam1
# is just the shared login node this is normally launched from.
case "$(hostname)" in
    rostam1*)
        partition=buran
        ;;
    medusa*)
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

for parcelport in "${parcelports[@]}"; do
    case "$parcelport" in
        mpi|tcp|lci) ;;
        *) echo "ERROR: unknown parcelport '$parcelport' (expected mpi, tcp or lci)" >&2; exit 1 ;;
    esac
    for nodes in 1 2 4 8 16; do
        # The 16-node sweeps outlast hpx_tests.sbatch's default 2-day limit.
        time_limit=()
        [[ "$nodes" -eq 16 ]] && time_limit=(--time=3-00:00:00)
        echo "Submitting HPX parcelport=$parcelport nodes=$nodes"
        sbatch --nodes="$nodes" \
               --partition="$partition" \
               --job-name="hpx_${parcelport}_n${nodes}" \
               ${time_limit[@]+"${time_limit[@]}"} \
               "${ROOT}/hpx_tests.sbatch" \
               --parcelport="$parcelport" --nodes="$nodes"
    done
done
