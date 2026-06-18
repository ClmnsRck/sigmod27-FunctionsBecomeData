--debugger pid print
select pg_backend_pid();
\pset pager off

--set debug_print_parse = on;

--meta flags, jit needs to be on, 'load llvm' loads dependencies
-- set jit='on';
-- load 'llvmjit.so';

-- set jit_above_cost = 0;             --enforce jit-usage
-- set jit_inline_above_cost = 0;      --enforce jit-usage
-- set jit_optimize_above_cost = 0;    --enforce jit-usage
set jit='off';                      --enforce no jit

--drop all tables, to create new ones
drop table if exists nums_smol;

------------------------------------------create new tables and fill them with usable data----------------------------------------------
create table nums_smol(x float not null, y float not null, z float not null, a float not null, b float not null, c float not null, d float not null);

-- NOTE: data is intentionally much larger than the lambda tables. Bump the
-- generate_series upper bound to stress the inner (data) loop harder.
insert into nums_smol (x, y, z, a, b, c, d)
select
    random()::float AS x,
    random()::float AS y,
    random()::float AS z,
    random()::float AS a,
    random()::float AS b,
    random()::float AS c,
    random()::float AS d
from generate_series(1, 10000);
--------------------------------------------------------- load all functions -----------------------------------------------------------
-- No UDFs needed here: this tester exercises *UDF-free* lambda calls only.
----------------------------------------------------------------------------------------------------------------------------------------

------------------------------------------------------Setup and Misc--------------------------------------------------------------------
-- \set ECHO all
----------------------------------------------------------------------------------------------------------------------------------------

------------------------------------------------------Test Higher-Order Lambdas---------------------------------------------------------
-- Drop old tables to make space for new ones
drop table if exists lambdas;
drop table if exists lambdas_ho;
drop table if exists lambdas_hoho;

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- First-Order Lambda Table
create table lambdas (
    id int primary key,
    f lambda(float8, float8 -> float8) not null,
    description TEXT
);
-- Higher-Order lambdas
create table lambdas_ho (
    id int primary key,
    g lambda(float8, float8, float8, (float8, float8 -> float8) -> float8) not null,
    description text
);
--Third-Order lambdas
create table lambdas_hoho (
    id int primary key,
    h lambda(float8, (float8, float8, float8, (float8, float8 -> float8) -> float8), (float8, float8 -> float8) -> float8) not null,
    description text
);

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- Sanity Check, wether the signature was stored correctly
SELECT
    c.relname AS table_name,
    a.attname AS column_name,
    a.atttypmod AS typmod,
    s.lamsigsrc
FROM pg_attribute a
JOIN pg_class c
  ON c.oid = a.attrelid
JOIN pg_lambdasig s
  ON s.lamsigid = a.atttypmod
WHERE a.atttypid = 'pg_catalog.lambda'::regtype
  AND a.attnum > 0
  AND NOT a.attisdropped
ORDER BY c.relname, a.attnum;

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- First-Order Lambdas (float, float → float)
insert into lambdas values
-- (1, lambda(x, y)(log(x + 1.0) + exp(y)), 'First-Order: Log-Exp transform'),
-- (2, lambda(x, y)(abs(x - y)), 'First-Order: Absolute difference'),
-- (3, lambda(x, y)(x^2 + y^2), 'First-Order: Euclidean norm squared'),
(4, lambda(x, y)(exp(x/10.0) + exp(y/10.0)), 'First-Order: Exp-Check'),
(5, lambda(x, y)(x + y), 'First-Order: Sanity Check(x + y)');

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- Second Order Lambdas (f, f, f, (f, f -> f) -> f)
insert into lambdas_ho values
-- (1, lambda(a, b, scale, op)(scale * op(a, b)), 'HO: scale binary lambda result'),
-- (2, lambda(a, b, myoffset, op)(op(a, b) + myoffset), 'HO: offset binary lambda result'),
-- (3, lambda(a, b, myweights, op)((myweights * op(a, b)) + ((1.0 - myweights) * a)), 'HO: weighted mix of op result and first input'),
(4, lambda(a, b, divisor, op)(op(a, b) * divisor), 'HO: multiplication'),
(5, lambda(a, b, c, op)(c + op(a, b)), 'HO: Sanity check(+)');

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- third Order Lambdas f, (f, f, f, (f, f -> f) -> f), (f, f -> f) -> f
insert into lambdas_hoho values
(1, lambda(a, op_ho, op)(a + op(a, a) * op_ho(a, a, a, op)), 'HOHO: multiplication');

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- ============================================================================
-- TIER 1: get the join order so the lambda relations are the OUTER driver
-- (their cross product = the set of lambda combinations) and the data table
-- is the INNER, rescanned once per combination.
--
-- Why this matters: with lambda-outer / data-inner, the lambda Datums feeding
-- each CallLambdaExpr are CONSTANT across the entire inner data scan. The
-- existing per-row value cache in ExecEvalCallLambdaExpr (the datum_image_eq
-- check) then collapses deserialize + ExecInit to ONCE PER COMBINATION instead
-- of once per output row -- i.e. assembly is hoisted above the data loop with
-- no engine change, purely by plan shape.
--
-- IMPORTANT empirical lesson (read the EXPLAIN ANALYZE output, look at "loops="):
--   * Stock GUCs control join ORDER (which rels join in what sequence) and join
--     METHOD (nestloop), but NOT the outer/inner ORIENTATION of a nestloop --
--     that stays cost-based. A hard orientation guarantee needs path
--     parameterization (required_outer), which is Tier 2 (a core change).
--   * In this realistic config (lambda tables tiny, data large) the planner
--     ALREADY picks lambda-outer / data-inner on its own -- see the BASELINE.
--   * Reliable Tier-1 recipe with stock GUCs:
--       join_collapse_limit / from_collapse_limit = 1  -> honor written FROM order
--       enable_hashjoin / enable_mergejoin = off        -> force nested-loop joins
--       write lambda tables FIRST, data table LAST in FROM
--       let the planner add its own Materialize on the inner (it does)
--   * DO NOT wrap the data in a MATERIALIZED CTE here: it flips the orientation
--     to data-OUTER / lambda-inner (the planner drives from the materialized
--     data), which is the WRONG shape and was ~8x slower in testing. A
--     cautionary example is kept (commented out) at the end of this section.
-- ============================================================================

\echo "=== BASELINE: planner's own choice (no forcing) ==="
-- With tiny lambda tables the planner already drives from the lambda
-- cross-product: look for the data node showing "loops=<#combinations>".
explain (analyze, costs on, verbose on, summary on)
select ns.x, ns.y, ns.z, lho.g(ns.x, ns.y, ns.z, l.f) as result
from lambdas l, lambdas_ho lho, nums_smol ns;

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- Pin the join order to exactly what is written in the FROM clause
set join_collapse_limit = 1;   -- honor written FROM/JOIN order
set from_collapse_limit = 1;   -- do not flatten subquery boundaries either
-- Force nested-loop joins (the only shape that gives a clean outer/inner loop)
set enable_hashjoin = off;
set enable_mergejoin = off;

\echo "=== TIER 1 FORCED: lambda relations OUTER, data INNER ==="
-- FROM order: lambda tables FIRST (outer driver, forms the combinations),
-- the data table LAST (inner). The planner adds a Materialize on nums_smol so
-- the per-combination rescans are cheap -> "loops=<#combinations>" on the data.
explain (analyze, costs on, verbose on, summary on)
select ns.x, ns.y, ns.z, lho.g(ns.x, ns.y, ns.z, l.f) as result
from lambdas_ho lho, lambdas l, nums_smol ns;

\echo "------------------------------------------------------------------------------------------------------------------------------"

\echo "=== TIER 1 FORCED: same, but lambda call in WHERE (filter) instead of target ==="
explain (analyze, costs on, verbose on, summary on)
select ns.x, ns.y, ns.z
from lambdas_ho lho, lambdas l, nums_smol ns
where lho.g(ns.x, ns.y, ns.z, l.f) >= 1;

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- CAUTIONARY (commented out): the MATERIALIZED-CTE variant flips orientation to
-- data-OUTER / lambda-inner. Uncomment and compare the "loops=" values + timing
-- to see the ~8x regression; this is exactly why Tier 2 (required_outer
-- parameterization) is needed for a real guarantee rather than GUC nudging.
-- explain (analyze, costs on, verbose on, summary on)
-- with d as materialized (select * from nums_smol)
-- select d.x, d.y, d.z, lho.g(d.x, d.y, d.z, l.f) as result
-- from lambdas_ho lho, lambdas l, d;

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- reset the join-ordering knobs to their defaults
reset join_collapse_limit;
reset from_collapse_limit;
reset enable_hashjoin;
reset enable_mergejoin;

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- Enable debugging
set custom_lambda_debugging_var TO on;
----------------------------------------------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------------------------
-- Disable debugging
set custom_lambda_debugging_var TO off;
\set ECHO none
\pset pager on
----------------------------------------------------------------------------------------------------------------------------------------
