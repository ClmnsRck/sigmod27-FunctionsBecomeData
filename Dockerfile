# Reproducibility image for the Functions Become Data artifact.
# Pinned to Ubuntu 24.04 (gcc 13.x, LLVM 18.x) to match the paper's build env.
#
#   docker build -t hol-artifact .
#   docker run --rm hol-artifact                 # runs the result-equivalence smoke test
#   docker run --rm -it hol-artifact bash        # interactive shell for the full benchmarks
#
# NOTE: the full benchmark.py run pins CPU affinity to the paper's topology and
# needs a many-core host; adjust the constants at the top of benchmark.py.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Build toolchain, PostgreSQL-from-source deps, LLVM/Clang (the lambda JIT) and OpenMP via gcc.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        make \
        clang \
        llvm \
        llvm-dev \
        flex \
        bison \
        perl \
        libreadline-dev \
        zlib1g-dev \
        libicu-dev \
        libssl-dev \
        pkg-config \
        python3 \
        python3-pip \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Python driver used by the benchmark runners (psycopg 3 with bundled libpq).
RUN pip3 install --no-cache-dir --break-system-packages "psycopg[binary]"

# PostgreSQL cannot run (initdb/server) as root, so build and run as a normal user.
RUN useradd --create-home --uid 1000 artifact
WORKDIR /artifact
COPY --chown=artifact:artifact . /artifact
USER artifact

# Build the modified PostgreSQL. The naked ./configure runs once so the build
# script's `make clean` works; complete_build.sh then re-configures with the
# project's flags, builds, installs, and initialises a pgdata/ + 'test' DB.
RUN cd hol-lambdas \
    && ./configure \
    && ./tools/complete_build.sh

# Default command: the fast HOL-vs-pure-SQL result-equivalence check (no CPU
# affinity, no special hardware). Override to run the full suite, e.g.:
#   docker run --rm hol-artifact bash -lc "python3 benchmark.py --types hol baseline"
CMD ["bash", "-lc", "cd additional-tests/equivalence && python3 run_equivalence.py"]
