// MPI reference benchmark for collective operations.
//
// Times MPI_Bcast, MPI_Reduce, MPI_Scatter, MPI_Gather, MPI_Allgather,
// MPI_Allreduce, and MPI_Alltoall over a configurable message size and
// iteration count, validates correctness, and appends per-run statistics
// (mean, variance, stddev, min, max, median) to
// result/mpi/<collective>/runtimes_<collective>_mpi.txt.
//
// All collectives share a single timing/recording harness (CollectiveBench::run);
// each collective only supplies its buffer setup, the timed MPI call, and a
// correctness check. Every collective is timed identically: a barrier-aligned
// start, the collective alone in the timed region, and an MPI_MAX reduction of
// the elapsed time so the slowest rank's latency is recorded.

#include <mpi.h>

#include <cxxopts.hpp>

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

constexpr int kRoot = 0;

int mpi_rank() {
    int rank = 0;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    return rank;
}

int mpi_size() {
    int size = 0;
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    return size;
}

struct Stats {
    double mean = 0.0;
    double variance = 0.0;  // population variance
    double stddev = 0.0;    // population standard deviation
    double min = 0.0;
    double max = 0.0;
    double median = 0.0;
};

Stats compute_stats(std::vector<double> data) {
    if (data.empty()) {
        return {};
    }

    // Mean and variance.
    double sum = 0.0;
    for (double x : data) {
        sum += x;
    }
    const double mean = sum / static_cast<double>(data.size());

    double variance_sum = 0.0;
    for (double x : data) {
        variance_sum += (x - mean) * (x - mean);
    }
    const double variance = variance_sum / static_cast<double>(data.size());
    const double stddev = std::sqrt(variance);

    // Min, max, median — data is taken by value so sorting in place is safe.
    std::sort(data.begin(), data.end());
    const double min = data.front();
    const double max = data.back();
    const std::size_t n = data.size();
    const double median = (n % 2 == 1)
        ? data[n / 2]
        : (data[n / 2 - 1] + data[n / 2]) / 2.0;

    return {mean, variance, stddev, min, max, median};
}

void create_parent_dir(const fs::path& file_path) {
    const fs::path dir = file_path.parent_path();
    if (dir.empty() || fs::exists(dir)) {
        return;
    }
    std::error_code ec;
    if (!fs::create_directories(dir, ec)) {
        throw std::runtime_error("Failed to create directory: " + dir.string() +
                                 " (" + ec.message() + ")");
    }
}

void write_to_file(const std::string& collective, const std::string& module,
                   int algorithm, int num_ranks, int rpn, int warmup,
                   int iterations, int size, const std::vector<double>& result) {
    const Stats stats = compute_stats(result);
    const int nodes = (rpn > 0) ? num_ranks / rpn : num_ranks;

    std::cout << "\nCollective:        " << collective
              << "\nModule:            " << module
              << "\nAlgorithm:         " << algorithm
              << "\nNodes:             " << nodes
              << "\nRanks:             " << num_ranks
              << "\nRanks/node:        " << rpn
              << "\nSize/Rank:         " << size
              << "\nWarmup iterations: " << warmup
              << "\nIterations:        " << iterations
              << "\nMean runtime:      " << stats.mean
              << "\nVariance:          " << stats.variance
              << "\nStd deviation:     " << stats.stddev
              << "\nMin runtime:       " << stats.min
              << "\nMax runtime:       " << stats.max
              << "\nMedian runtime:    " << stats.median << '\n'
              << std::flush;

    const fs::path out_path = fs::path("result") / "mpi" / std::to_string(num_ranks) / collective /
                              std::to_string(algorithm) /
                              ("runtimes_" + collective + "_mpi.txt");
    create_parent_dir(out_path);

    static const std::string header =
        "collective;module;algorithm;nodes;ranks;rpn;size;warmup;iterations;mean;variance;stddev;min;max;median\n";

    // Write the header only once, when the file is new or empty.
    bool need_header = true;
    if (std::ifstream in{out_path}; in.good()) {
        need_header = (in.peek() == std::ifstream::traits_type::eof());
    }

    std::ofstream out(out_path, std::ios_base::app);
    if (!out) {
        throw std::runtime_error("Failed to open output file: " + out_path.string());
    }
    if (need_header) {
        out << header;
    }
    out << collective << ';' << module << ';' << algorithm << ';' << nodes << ';'
        << num_ranks << ';' << rpn << ';' << size << ';' << warmup << ';'
        << iterations << ';' << stats.mean << ';' << stats.variance << ';'
        << stats.stddev << ';' << stats.min << ';' << stats.max << ';'
        << stats.median << '\n';
}

// Shared driver for all collectives: runs `iterations` timed rounds and records
// the result on the root rank. Each collective supplies:
//   prepare(i)    - untimed per-iteration buffer setup
//   collective()  - the timed MPI call
//   check(i)      - correctness validation
//
// Timing is identical for every collective so the numbers are directly
// comparable: each iteration starts from a shared MPI_Barrier, times only the
// collective call (no trailing barrier inside the timed region), and reduces
// the per-rank elapsed time with MPI_MAX onto root. The max captures the
// slowest rank's latency, i.e. when the operation is actually complete for the
// whole job — meaningful for both symmetric and asymmetric collectives.
struct CollectiveBench {
    std::string name;
    std::string module;
    int algorithm = 0;
    int rpn = 16;
    int iterations = 10;
    int warmup = 0;  // real default supplied by --warmup_iterations
    int test_size = 1;

    template <typename Prepare, typename Collective, typename Check>
    void run(Prepare prepare, Collective collective, Check check) const {
        const int rank = mpi_rank();
        const int size = mpi_size();
        std::vector<double> result(static_cast<std::size_t>(std::max(iterations, 0)), 0.0);

        // Untimed warmup — allows MPI to initialise internal buffers and
        // routes so that iteration 0 of the timed loop is not an outlier.
        for (int i = 0; i < warmup; ++i) {
            prepare(i);
            MPI_Barrier(MPI_COMM_WORLD);
            collective();
        }

        for (int i = 0; i < iterations; ++i) {
            prepare(i);

            // Synchronise all ranks before timing to eliminate entry-skew noise.
            MPI_Barrier(MPI_COMM_WORLD);
            const double t_before = MPI_Wtime();
            collective();
            const double t_elapsed = MPI_Wtime() - t_before;

            // Reduce the elapsed time with MPI_MAX so root records the slowest
            // rank's latency. Applied uniformly to all collectives so their
            // measurements are comparable. Done outside the timed region.
            double t_record = t_elapsed;
            MPI_Reduce(rank == kRoot ? MPI_IN_PLACE : &t_elapsed, &t_record,
                       1, MPI_DOUBLE, MPI_MAX, kRoot, MPI_COMM_WORLD);

            if (rank == kRoot) {
                result[static_cast<std::size_t>(i)] = t_record;
            }
            check(i);
        }

        if (rank == kRoot) {
            write_to_file(name, module, algorithm, size, rpn, warmup, iterations,
                          test_size, result);
        }
    }
};

void validate_algorithm_applicability(const CollectiveBench& cfg) {
    const bool is_two_proc =
        (cfg.name == "all_gather" && cfg.algorithm == 6) ||
        (cfg.name == "all_to_all" && cfg.algorithm == 5);
    const int ranks = mpi_size();
    if (is_two_proc && ranks != 2) {
        throw std::invalid_argument(
            "Open MPI tuned " + cfg.name + " algorithm " +
            std::to_string(cfg.algorithm) +
            " is two_proc and requires exactly 2 ranks; got " +
            std::to_string(ranks));
    }
}

void test_scatter(const CollectiveBench& cfg) {
    const int rank = mpi_rank();
    const int size = mpi_size();
    // Allocate once; prepare() only refills values to avoid per-iteration
    // heap allocation inside the timed loop.
    std::vector<int> send_data(static_cast<std::size_t>(size) * cfg.test_size, 0);
    std::vector<int> recv_data(static_cast<std::size_t>(cfg.test_size), 0);

    cfg.run(
        [&](int i) {
            if (rank == kRoot) {
                for (int j = 0; j < size; ++j) {
                    const auto block = static_cast<std::ptrdiff_t>(j) * cfg.test_size;
                    std::fill(send_data.begin() + block,
                              send_data.begin() + block + cfg.test_size,
                              42 + i + j);
                }
            }
        },
        [&] {
            MPI_Scatter(send_data.data(), cfg.test_size, MPI_INT, recv_data.data(),
                        cfg.test_size, MPI_INT, kRoot, MPI_COMM_WORLD);
        },
        [&](int i) {
            for (int value : recv_data) {
                if (value != 42 + i + rank) {
                    std::cerr << "ERROR: scatter mismatch (size " << cfg.test_size
                              << ", ranks " << size << ")\n";
                    break;
                }
            }
        });
}

void test_broadcast(const CollectiveBench& cfg) {
    const int rank = mpi_rank();
    const int size = mpi_size();
    std::vector<int> data(static_cast<std::size_t>(cfg.test_size), 0);

    cfg.run(
        [&](int i) {
            if (rank == kRoot) {
                std::fill(data.begin(), data.end(), i);
            }
        },
        [&] { MPI_Bcast(data.data(), cfg.test_size, MPI_INT, kRoot, MPI_COMM_WORLD); },
        [&](int i) {
            if (!data.empty() && data[0] != i) {
                std::cerr << "ERROR: broadcast mismatch (size " << cfg.test_size
                          << ", ranks " << size << ")\n";
            }
        });
}

void test_reduce(const CollectiveBench& cfg) {
    const int rank = mpi_rank();
    const int size = mpi_size();
    std::vector<int> send_data(static_cast<std::size_t>(cfg.test_size), 0);
    std::vector<int> recv_data(static_cast<std::size_t>(cfg.test_size), 0);

    cfg.run(
        [&](int i) { std::fill(send_data.begin(), send_data.end(), i); },
        [&] {
            MPI_Reduce(send_data.data(), recv_data.data(), cfg.test_size, MPI_INT,
                       MPI_SUM, kRoot, MPI_COMM_WORLD);
        },
        [&](int i) {
            if (rank == kRoot && !recv_data.empty() && recv_data[0] != size * i) {
                std::cerr << "ERROR: reduce mismatch (size " << cfg.test_size
                          << ", ranks " << size << ")\n";
            }
        });
}

void test_gather(const CollectiveBench& cfg) {
    const int rank = mpi_rank();
    const int size = mpi_size();
    std::vector<int> send_data(static_cast<std::size_t>(cfg.test_size), rank);
    std::vector<int> recv_data(static_cast<std::size_t>(cfg.test_size) * size, 0);

    cfg.run(
        [&](int) {},
        [&] {
            MPI_Gather(send_data.data(), cfg.test_size, MPI_INT, recv_data.data(),
                       cfg.test_size, MPI_INT, kRoot, MPI_COMM_WORLD);
        },
        [&](int) {
            if (rank != kRoot) {
                return;
            }
            for (int j = 0; j < size; ++j) {
                if (recv_data[static_cast<std::size_t>(j) * cfg.test_size] != j) {
                    std::cerr << "ERROR: gather mismatch (size " << cfg.test_size
                              << ", ranks " << size << ")\n";
                    break;
                }
            }
        });
}

void test_all_gather(const CollectiveBench& cfg) {
    const int rank = mpi_rank();
    const int size = mpi_size();
    std::vector<int> send_data(static_cast<std::size_t>(cfg.test_size), rank);
    std::vector<int> recv_data(static_cast<std::size_t>(cfg.test_size) * size, 0);

    cfg.run(
        [&](int) {},
        [&] {
            MPI_Allgather(send_data.data(), cfg.test_size, MPI_INT, recv_data.data(),
                          cfg.test_size, MPI_INT, MPI_COMM_WORLD);
        },
        [&](int) {
            for (int j = 0; j < size; ++j) {
                if (recv_data[static_cast<std::size_t>(j) * cfg.test_size] != j) {
                    std::cerr << "ERROR: all_gather mismatch (size " << cfg.test_size
                              << ", ranks " << size << ")\n";
                    break;
                }
            }
        });
}

void test_all_reduce(const CollectiveBench& cfg) {
    const int size = mpi_size();
    std::vector<int> send_data(static_cast<std::size_t>(cfg.test_size), 0);
    std::vector<int> recv_data(static_cast<std::size_t>(cfg.test_size), 0);

    cfg.run(
        [&](int i) { std::fill(send_data.begin(), send_data.end(), i); },
        [&] {
            MPI_Allreduce(send_data.data(), recv_data.data(), cfg.test_size, MPI_INT,
                          MPI_SUM, MPI_COMM_WORLD);
        },
        [&](int i) {
            if (!recv_data.empty() && recv_data[0] != size * i) {
                std::cerr << "ERROR: all_reduce mismatch (size " << cfg.test_size
                          << ", ranks " << size << ")\n";
            }
        });
}

void test_all_to_all(const CollectiveBench& cfg) {
    const int rank = mpi_rank();
    const int size = mpi_size();
    std::vector<int> send_data(static_cast<std::size_t>(cfg.test_size) * size, 0);
    std::vector<int> recv_data(static_cast<std::size_t>(cfg.test_size) * size, 0);

    cfg.run(
        [&](int i) {
            for (int j = 0; j < size; ++j) {
                const auto block = static_cast<std::ptrdiff_t>(j) * cfg.test_size;
                std::fill(send_data.begin() + block,
                          send_data.begin() + block + cfg.test_size,
                          rank + j + i);
            }
        },
        [&] {
            MPI_Alltoall(send_data.data(), cfg.test_size, MPI_INT, recv_data.data(),
                         cfg.test_size, MPI_INT, MPI_COMM_WORLD);
        },
        [&](int i) {
            for (int j = 0; j < size; ++j) {
                const int expected = j + rank + i;
                if (recv_data[static_cast<std::size_t>(j) * cfg.test_size] != expected) {
                    std::cerr << "ERROR: all_to_all mismatch (size " << cfg.test_size
                              << ", ranks " << size << ")\n";
                    break;
                }
            }
        });
}

}  // namespace

int main(int argc, char** argv) {
    MPI_Init(&argc, &argv);

    cxxopts::Options options("benchmark_collectives_mpi",
                             "MPI reference benchmark for collective operations");
    options.add_options()
        ("rpn", "Number of ranks per node",
         cxxopts::value<int>()->default_value("16"))
        ("algorithm", "Algorithm id for the operation (recorded in output)",
         cxxopts::value<int>()->default_value("0"))
        ("m,module", "Collective module label recorded in output",
         cxxopts::value<std::string>()->default_value("tuned"))
        ("iterations", "Number of timed iterations",
         cxxopts::value<int>()->default_value("10"))
        ("warmup_iterations", "Number of untimed warmup iterations",
         cxxopts::value<int>()->default_value("3"))
        ("t,test_size", "Number of ints sent per rank",
         cxxopts::value<int>()->default_value("1"))
        ("operation", "Collective to run: broadcast|reduce|scatter|gather|all_gather|all_reduce|all_to_all",
         cxxopts::value<std::string>()->default_value("scatter"))
        ("h,help", "Print usage");

    int exit_code = 0;
    try {
        const auto parsed = options.parse(argc, argv);
        if (parsed.count("help") != 0u) {
            if (mpi_rank() == kRoot) {
                std::cout << options.help() << '\n';
            }
            MPI_Finalize();
            return 0;
        }

        CollectiveBench cfg;
        cfg.rpn = parsed["rpn"].as<int>();
        cfg.algorithm = parsed["algorithm"].as<int>();
        cfg.module = parsed["module"].as<std::string>();
        cfg.iterations = parsed["iterations"].as<int>();
        cfg.warmup = parsed["warmup_iterations"].as<int>();
        cfg.test_size = parsed["test_size"].as<int>();
        cfg.name = parsed["operation"].as<std::string>();

        validate_algorithm_applicability(cfg);

        if (cfg.name == "scatter") {
            test_scatter(cfg);
        } else if (cfg.name == "reduce") {
            test_reduce(cfg);
        } else if (cfg.name == "broadcast") {
            test_broadcast(cfg);
        } else if (cfg.name == "gather") {
            test_gather(cfg);
        } else if (cfg.name == "all_gather") {
            test_all_gather(cfg);
        } else if (cfg.name == "all_reduce") {
            test_all_reduce(cfg);
        } else if (cfg.name == "all_to_all") {
            test_all_to_all(cfg);
        } else {
            if (mpi_rank() == kRoot) {
                std::cerr << "Unknown operation: " << cfg.name
                          << " (expected broadcast|reduce|scatter|gather|all_gather|all_reduce|all_to_all)\n";
            }
            exit_code = 1;
        }
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << '\n';
        exit_code = 1;
    }

    MPI_Finalize();
    return exit_code;
}
