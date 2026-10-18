# additional-tests

Checks and measurements outside the main suite (`benchmark.py`, `run_usecase_benchmark.py`
in the repo root).

| dir | what it does |
|---|---|
| `equivalence/` | the map operator, the free lambdas and the CASE baseline compute the same results; run by `run_all.sh` (see its README) |
| `timing/` | phase breakdown of the map operator (combined_timing figure): `run_ptime.py` builds an instrumented copy of `apply_mt_pw`, measures, `agg_ptime.py` writes the figure's CSVs |
