#!/usr/bin/env bash
# Clone, configure and build HPX with the TCP/MPI/LCI parcelports, then build
# the collectives benchmark target.
set -exo pipefail
# Load compiler and dependencies
case "$(hostname)" in
    rostam1|medusa*|buran*)
        module load gcc/14.2.0
        module load openmpi/5.0.5
        ;;
    qbd*)
        spack load gcc@14.3.0
        #module load hwloc
        spack load openmpi@5.0.10
        export CPATH=$(echo "${CPATH:-}" | tr ':' '\n' | grep -v "intel.*mpi" | tr '\n' ':' | sed 's/:$//')
        ;;
    *)
        echo "ERROR: unknown host $(hostname), cannot load modules" >&2
        exit 1
        ;;
esac

# Configuration
export CC=gcc
export CXX=g++

BUILD_TYPE=Release
CMAKE_COMMAND=cmake
#HPX_VERSION=master
HPX_VERSION=improve_collective_benchmark
TCP=ON
MPI=ON
LCI=ON

# Optional build flags (default to empty if unset).
CXXFLAGS="${CXXFLAGS:-}"
LDCXXFLAGS="${LDCXXFLAGS:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR_SRC=${ROOT}/hpx
DIR_BUILD=${ROOT}/build/hpx
DIR_INSTALL=${DIR_INSTALL:-${DIR_BUILD}/install}

#DOWNLOAD_URL="git@github.com:STEllAR-GROUP/hpx.git"
#DOWNLOAD_URL="https://github.com/STEllAR-GROUP/hpx.git"
DOWNLOAD_URL="https://github.com/constracktor/hpx.git"

# Clone HPX if not present
if [[ ! -d ${DIR_SRC} ]]; then
    (
      mkdir -p ${DIR_SRC}
      cd ${DIR_SRC}
      git clone ${DOWNLOAD_URL} .
      git checkout ${HPX_VERSION}
    )
fi
# Create build directory if not present
if [[ ! -d ${DIR_BUILD} ]]; then
    (
      mkdir -p ${DIR_BUILD}
    )
fi
# Configure with cmake if not present
if [[ ! -d ${DIR_BUILD}/CMakeFiles ]]; then
    (
        ${CMAKE_COMMAND} \
            -H${DIR_SRC} \
            -B${DIR_BUILD} \
            -DCMAKE_INSTALL_PREFIX=${DIR_INSTALL} \
            -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
            -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
            -DCMAKE_EXE_LINKER_FLAGS="${LDCXXFLAGS}" \
            -DCMAKE_SHARED_LINKER_FLAGS="${LDCXXFLAGS}" \
            -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
            -DHPX_WITH_MALLOC=system \
            -DHPX_WITH_NETWORKING=ON \
            -DHPX_WITH_DISTRIBUTED_RUNTIME=ON \
            -DHPX_WITH_MORE_THAN_64_THREADS=ON \
            -DHPX_WITH_MAX_CPU_COUNT=256 \
            -DHPX_WITH_LOGGING=OFF \
            -DHPX_WITH_EXAMPLES=OFF \
            -DHPX_WITH_TESTS=ON \
            -DHPX_WITH_APEX=OFF \
            -DHPX_WITH_PKGCONFIG=OFF \
            -DHPX_WITH_PARCELPORT_TCP=${TCP} \
            -DHPX_WITH_PARCELPORT_MPI=${MPI} \
            -DHPX_WITH_PARCELPORT_LCI=${LCI} \
            -DHPX_WITH_FETCH_LCI=${LCI} \
            -DHPX_WITH_FETCH_BOOST=ON \
            -DHPX_WITH_FETCH_HWLOC=OFF \
            -DHPX_WITH_FETCH_ASIO=ON
    )
fi

# Compile
${CMAKE_COMMAND} --build ${DIR_BUILD} --target tests.performance.modules.collectives.benchmark_collectives -- -j
