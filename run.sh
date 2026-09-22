#!/usr/bin/env bash
# Submit HPX benchmark jobs at node counts 1, 2, 4, 8, 16 for mpi and tcp
# parcelports, plus 1, 2, 4, 8 for lci. hpx_tests.sbatch sweeps every
# collective except barrier, sizes 1-65536, arity -1 and 2.
#
# lci is capped at 8 nodes (256 ranks) here, for two independent reasons
# confirmed today:
#   1. HPX's lci parcelport opens one IB QP per remote rank per process,
#      hitting a ~485-507 QP/process ceiling (see hpx_tests.sbatch for the
#      ndevices/default-device fix that brought this down from a 3x to a 1x
#      multiplier). 8 nodes x 32 ranks = 256 QPs/process, confirmed working;
#      16 nodes x 32 ranks = 512 sits right at/over that ceiling.
#   2. Separately, LCI's own PMIx-based bootstrap exchange is an O(N^2)
#      pattern that hard-hangs well before the QP ceiling even at reduced
#      ranks/node (confirmed: 480 ranks hung completely). A local patch to
#      LCI's PMIx wrapper (lct/pmi/pmi_wrapper_pmix.cpp, in the FetchContent
#      build tree, not durable across a clean rebuild) is being verified --
#      raise this cap only once 16 nodes has actually been re-tested and
#      shown to complete.
# mpi and tcp don't share either limitation (no IB QP mesh, no PMIx-bootstrap
# wireup in this failure path) and are confirmed working at 8 nodes with no
# indication they wouldn't scale to 16 the same as they always have.
#
# Does NOT submit the MPI reference benchmark. Each (parcelport, node count)
# becomes one sbatch job.
# Usage: ./run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

for nodes in 1 2 4 8 16; do
    echo "Submitting HPX parcelport=mpi nodes=$nodes"
    sbatch --nodes="$nodes" \
           --partition="$partition" \
           --job-name="hpx_mpi_n${nodes}" \
           "${ROOT}/hpx_tests.sbatch" \
           --parcelport=mpi --nodes="$nodes"
done

for nodes in 1 2 4 8 16; do
    echo "Submitting HPX parcelport=tcp nodes=$nodes"
    sbatch --nodes="$nodes" \
           --partition="$partition" \
           --job-name="hpx_tcp_n${nodes}" \
           "${ROOT}/hpx_tests.sbatch" \
           --parcelport=tcp --nodes="$nodes"
done

for nodes in 1 2 4 8; do
    echo "Submitting HPX parcelport=lci nodes=$nodes"
    sbatch --nodes="$nodes" \
           --partition="$partition" \
           --job-name="hpx_lci_n${nodes}" \
           "${ROOT}/hpx_tests.sbatch" \
           --parcelport=lci --nodes="$nodes"
done
