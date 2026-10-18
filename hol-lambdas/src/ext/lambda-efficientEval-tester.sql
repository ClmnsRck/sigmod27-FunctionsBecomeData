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

-- data is much larger than the lambda tables on purpose
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
-- none: this tester only uses UDF-free lambda calls
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
-- Join orientation of UDF-free lambda calls: lambda tables outer (their cross
-- product = the lambda combinations), data inner; compare the "loops=" values.
-- Stock GUCs fix join order and method, not the nestloop orientation. With tiny
-- lambda tables the planner picks lambda-outer on its own (BASELINE). The
-- CallLambdaExpr runtime cache (lambda_cache.c) builds each body once per
-- combination in either orientation, as long as they fit custom_lambda_cache_size.
-- ============================================================================

\echo "=== BASELINE: planner's own choice (no forcing) ==="
-- the data node should show "loops=<#combinations>"
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
-- lambda tables first, data last in FROM
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

-- a MATERIALIZED CTE flips the orientation to data outer / lambda inner:
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
