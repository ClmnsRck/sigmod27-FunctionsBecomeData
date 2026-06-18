--debugger pid print
select pg_backend_pid();
\pset pager off

--set debug_print_parse = on;

--meta flags, jit needs to be on, 'load llvm' loads dependencies
set jit='on';
load 'llvmjit.so';

set jit_above_cost = 0;             --enforce jit-usage
set jit_inline_above_cost = 0;      --enforce jit-usage
set jit_optimize_above_cost = 0;    --enforce jit-usage
set jit='off';                      --enforce no jit

--drop all tables, to create new ones
drop table if exists nums_smol;

------------------------------------------create new tables and fill them with usable data----------------------------------------------
create table nums_smol(x float not null, y float not null, z float not null, a float not null, b float not null, c float not null, d float not null);

insert into nums_smol (x, y, z, a, b, c, d)
select
    random()::float AS x,
    random()::float AS y,
    random()::float AS z,
    random()::float AS a,
    random()::float AS b,
    random()::float AS c,
    random()::float AS d
from generate_series(1, 30000);
--------------------------------------------------------- load all functions -----------------------------------------------------------
create or replace function apply_mt_agg("lambda", lambdatable, lambdatable, int, int)
returns setof record
as '$libdir/../../../src/ext/apply_mt_agg_ext.so','apply_mt_agg'
language C STRICT;
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

-- \echo "------------------------------------------------------------------------------------------------------------------------------"

-- -- inserted lambdas
-- select * from lambdas;
-- select * from lambdas_ho;
-- select * from lambdas_hoho;

-- \echo "------------------------------------------------------------------------------------------------------------------------------"

-- -- test first-order lambdas outside of UDFs
-- \echo "First-order test"
-- select ns.x, ns.y, l.f(ns.x, ns.y) as result, l.description
-- from nums_smol ns, lambdas l;

-- \echo "------------------------------------------------------------------------------------------------------------------------------"

-- -- test higher-order lambdas outside of UDFs
-- \echo "Second-Order test"
-- select ns.x, ns.y, ns.z, lho.g(ns.x, ns.y, ns.z, l.f) as result, l.description, lho.description
-- from lambdas l, lambdas_ho lho, nums_smol ns;

-- \echo "------------------------------------------------------------------------------------------------------------------------------"

-- -- test higher-order lambdas outside of UDFs
-- \echo "Third-Order test"
-- select ns.x, l_hoho.h(ns.x, lho.g, l.f)  as result
-- from lambdas l, lambdas_ho lho, lambdas_hoho l_hoho, nums_smol ns;

-- \echo "------------------------------------------------------------------------------------------------------------------------------"

-- -- test lambdas not in target_entry, but where condition
-- select ns.x, ns.y, ns.z
-- from lambdas l, lambdas_ho lho, nums_smol ns
-- where lho.g(ns.x, ns.y, ns.z, l.f) >= 1;

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- encourage a parallel plan for the next EXPLAIN ANALYZE
set max_parallel_workers = 8;
set max_parallel_workers_per_gather = 4;
set min_parallel_table_scan_size = 0;
set min_parallel_index_scan_size = 0;
set parallel_setup_cost = 0;
set parallel_tuple_cost = 0;
-- set force_parallel_mode = on;
set enable_parallel_append = on;
set enable_parallel_hash = on;

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- build a single-relation helper table so a later parallel-safe CallLambdaExpr
-- can be attached to the scan itself instead of remaining a join-level expr
drop table if exists nums_smol_lambda_scan;
create table nums_smol_lambda_scan (x, y, z, f, g) as
select ns.x,
       ns.y,
       ns.z,
       l.f,
       lho.g
from nums_smol ns, lambdas l, lambdas_ho lho;

analyze nums_smol_lambda_scan;

\echo "Single-relation Parallel EXPLAIN ANALYZE candidate"
explain (analyze, costs on, verbose on, summary on)
select h.x,
       h.y,
       h.z,
       h.g(h.x, h.y, h.z, h.f) as result
from nums_smol_lambda_scan h
where h.g(h.x, h.y, h.z, h.f) >= 1;

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- reset parallel planner settings to their defaults
reset max_parallel_workers;
reset max_parallel_workers_per_gather;
reset min_parallel_table_scan_size;
reset min_parallel_index_scan_size;
reset parallel_setup_cost;
reset parallel_tuple_cost;
-- reset force_parallel_mode;
reset enable_parallel_append;
reset enable_parallel_hash;

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
