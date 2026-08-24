#!/usr/bin/env bash
# Build the MPI reference benchmark.
# Produces: build/mpi/bin/benchmark_collectives_mpi
set -euo pipefail

# Load dependencies
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${ROOT}/mpi"
BUILD_DIR="${ROOT}/build/mpi"

# Configure and build with CMake. cxxopts is located via find_package, or
# fetched automatically if it is not installed (see mpi/CMakeLists.txt).
cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release
cmake --build "${BUILD_DIR}" -j

echo "Built: ${BUILD_DIR}/bin/benchmark_collectives_mpi"
