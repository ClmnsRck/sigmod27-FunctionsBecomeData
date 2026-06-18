-- Per-query/session knobs 
SET jit = off;
SET work_mem = '8GB';
SET hash_mem_multiplier = 1.0;
SET temp_file_limit = '75GB';
SET maintenance_work_mem = '8GB';

-- Improve logging
SET track_io_timing = on;
SET log_temp_files = 0;

-- Ensure spills land under ./<repo>/pgdata-temp
SET temp_tablespaces = benchtemp;

-- Optional planner toggles
SET enable_nestloop = on;
SET enable_hashjoin = off;
SET enable_hashagg = off;
SET enable_mergejoin = on;
SET enable_parallel_append = on;
SET plan_cache_mode = force_custom_plan;
