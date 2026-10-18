# Build and test environment for the Functions Become Data artifact.
# Ubuntu 24.04 (gcc 13, LLVM 18) matches the paper's build.
#
#   docker build -t hol-lambdas .
#   docker run --rm --shm-size=8g hol-lambdas            # equivalence check, no special hardware
#   docker run --rm -it --shm-size=8g hol-lambdas bash   # a shell, e.g. ./run_all.sh --smoke --topology local
#
# --shm-size: the map operator's results travel through shared memory (1.3 GB at the
# largest point), and the benchmark clusters reserve 4 GB of it at start.
#
# The benchmark runners pin CPUs (see README.md, "Hardware"); for comparable timings run
# them on a machine like the paper's, not in a container on a laptop.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential make flex bison perl \
        clang llvm llvm-dev \
        libicu-dev pkg-config libreadline-dev zlib1g-dev \
        python3 python3-psycopg python3-pandas \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# PostgreSQL does not run as root; the scripts create folders next to themselves
RUN useradd --create-home artifact && install -d -o artifact -g artifact /artifact
WORKDIR /artifact
COPY --chown=artifact:artifact . /artifact
USER artifact

RUN bash build_helper.sh

CMD ["bash", "-lc", "python3 generate_benchmarks.py && python3 generate_usecase_benchmarks.py && python3 additional-tests/equivalence/run_equivalence.py"]
