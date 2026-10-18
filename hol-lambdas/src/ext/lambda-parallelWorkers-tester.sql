--debugger pid print
select pg_backend_pid();
\pset pager off

--set debug_print_parse = on;

--meta flags, jit needs to be on, 'load llvm' loads dependencies
set jit='on';
load 'llvmjit.so';

--no jit_above_cost = 0: the operators force jit for their lambdas anyway, and
--forcing it for the query too makes apply_mt fail ("failed to JIT: evalexpr_N_M")

--4 workers fit a default cluster's max_worker_processes
set max_parallel_workers = 8;

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
-- apply_mt on parallel workers. arg 4 = workers, arg 5 = level: 0 = checked
-- (L1 with jit off, L2 with jit on), 1 = fast JIT (L3), 2 = L3 plus row tuple
create or replace function apply_mt_pw("lambda", lambdatable, lambdatable, int, int)
returns setof record
as '$libdir/../../../src/ext/apply_mt_pw_ext.so','apply_mt_pw'
language C STRICT;

-- the threaded original, for the equivalence check
create or replace function apply_mt("lambda", lambdatable, lambdatable, int, int)
returns setof record
as '$libdir/../../../src/ext/apply_mt_ext.so','apply_mt'
language C STRICT;

----------------------------------------------------------------------------------------------------------------------------------------

------------------------------------------------------Setup and Misc--------------------------------------------------------------------
-- \set ECHO all
----------------------------------------------------------------------------------------------------------------------------------------

------------------------------------------------------Test Higher-Order Lambdas---------------------------------------------------------
-- Drop old tables to make space for new ones
drop table if exists lambdas;
drop table if exists lambdas_ho;
drop table if exists lambdas_table_helper;

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- First-Order Lambda Table (signature on the column, lambda column first: apply
-- reads the lambdas off the front of the second sublink)
create table lambdas (
    f lambda(float8, float8 -> float8) not null,
    description TEXT
);
-- Higher-Order lambdas
create table lambdas_ho (
    g lambda(float8, float8, float8, (float8, float8 -> float8) -> float8) not null,
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
(lambda(x, y)(log(x + 1.0) + exp(y)), 'First-Order: Log-Exp transform'),
(lambda(x, y)(abs(x - y)), 'First-Order: Absolute difference'),
(lambda(x, y)(x^2 + y^2), 'First-Order: Euclidean norm squared'),
(lambda(x, y)(exp(x/10.0) + exp(y/10.0)), 'First-Order: Exp-Check'),
(lambda(x, y)(x + y), 'First-Order: Sanity Check(x + y)');

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- Second Order Lambdas (f, f, f, (f, f -> f) -> f)
insert into lambdas_ho values
(lambda(a, b, scale, op)(scale * op(a, b)), 'HO: scale binary lambda result'),
(lambda(a, b, myoffset, op)(op(a, b) + myoffset), 'HO: offset binary lambda result'),
(lambda(a, b, divisor, op)(op(a, b) * divisor), 'HO: multiplication'),
(lambda(a, b, c, op)(c + op(a, b)), 'HO: Sanity check(+)');

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- one row per lambda combination, lambda columns only, so the second sublink is
-- exactly b:[f, g]
create table lambdas_table_helper as
select f, g
from lambdas cross join lambdas_ho;

analyze;

\echo "------------------------------------------------------------------------------------------------------------------------------"

------------------------------------------------------Equivalence with apply_mt---------------------------------------------------------
-- same lambdas, same data, threads vs. processes: the two result sets have to
-- be identical, row for row
\echo "Equivalence: apply_mt (threads) vs apply_mt_pw (workers, fast path)"
select count(*) as rows_only_in_one_side
from (
    (select x, y, z, result
     from apply_mt(
        lambda(a:[x:float, y:float, z:float],
               b:[f:(float,float->float),
                  g:(float,float,float,(float,float->float)->float)])
          (b.g(a.x, a.y, a.z, b.f) + a.z),
        (select x, y, z from nums_smol limit 5000),
        (select * from lambdas_table_helper),
        4, 0)
     except all
     select x, y, z, result
     from apply_mt_pw(
        lambda(a:[x:float, y:float, z:float],
               b:[f:(float,float->float),
                  g:(float,float,float,(float,float->float)->float)])
          (b.g(a.x, a.y, a.z, b.f) + a.z),
        (select x, y, z from nums_smol limit 5000),
        (select * from lambdas_table_helper),
        4, 1))
) as diff;

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- the three execution levels have to agree with each other as well
\echo "Level agreement: checked / fast / fast+tuple over the same input"
select mode, count(*) as rows, round(sum(result)::numeric, 6) as checksum
from (
    select 0 as mode, result from apply_mt_pw(
        lambda(a:[x:float, y:float, z:float],
               b:[f:(float,float->float),
                  g:(float,float,float,(float,float->float)->float)])
          (b.g(a.x, a.y, a.z, b.f) + a.z),
        (select x, y, z from nums_smol limit 5000),
        (select * from lambdas_table_helper),
        4, 0)
    union all
    select 1 as mode, result from apply_mt_pw(
        lambda(a:[x:float, y:float, z:float],
               b:[f:(float,float->float),
                  g:(float,float,float,(float,float->float)->float)])
          (b.g(a.x, a.y, a.z, b.f) + a.z),
        (select x, y, z from nums_smol limit 5000),
        (select * from lambdas_table_helper),
        4, 1)
    union all
    select 2 as mode, result from apply_mt_pw(
        lambda(a:[x:float, y:float, z:float],
               b:[f:(float,float->float),
                  g:(float,float,float,(float,float->float)->float)])
          (b.g(a.x, a.y, a.z, b.f) + a.z),
        (select x, y, z from nums_smol limit 5000),
        (select * from lambdas_table_helper),
        4, 2)
) as levels
group by mode
order by mode;

\echo "------------------------------------------------------------------------------------------------------------------------------"

------------------------------------------------------Execution levels------------------------------------------------------------------
\timing on

-- L1: the interpreter. Only reachable because every evaluator is a full
-- backend; apply_mt's threads cannot run this path at all
set jit='off';
\echo "L1 interpreted (mode 0, jit off), 4 workers"
select count(*) from apply_mt_pw(
    lambda(a:[x:float, y:float, z:float],
           b:[f:(float,float->float),
              g:(float,float,float,(float,float->float)->float)])
      (b.g(a.x, a.y, a.z, b.f) + a.z),
    (select x, y, z from nums_smol limit 5000),
    (select * from lambdas_table_helper),
    4, 0);

-- L2: the standard, fully checked expression JIT
set jit='on';
\echo "L2 standard expression JIT (mode 0, jit on), 4 workers"
select count(*) from apply_mt_pw(
    lambda(a:[x:float, y:float, z:float],
           b:[f:(float,float->float),
              g:(float,float,float,(float,float->float)->float)])
      (b.g(a.x, a.y, a.z, b.f) + a.z),
    (select x, y, z from nums_smol limit 5000),
    (select * from lambdas_table_helper),
    4, 0);

-- L3: the fast path, the only level apply_mt's threads can use
\echo "L3 fast-path JIT (mode 1), 4 workers"
select count(*) from apply_mt_pw(
    lambda(a:[x:float, y:float, z:float],
           b:[f:(float,float->float),
              g:(float,float,float,(float,float->float)->float)])
      (b.g(a.x, a.y, a.z, b.f) + a.z),
    (select x, y, z from nums_smol limit 5000),
    (select * from lambdas_table_helper),
    4, 1);

\echo "L3 fast-path JIT + row tuple (mode 2), 4 workers"
select count(*) from apply_mt_pw(
    lambda(a:[x:float, y:float, z:float],
           b:[f:(float,float->float),
              g:(float,float,float,(float,float->float)->float)])
      (b.g(a.x, a.y, a.z, b.f) + a.z),
    (select x, y, z from nums_smol limit 5000),
    (select * from lambdas_table_helper),
    4, 2);

\echo "------------------------------------------------------------------------------------------------------------------------------"

------------------------------------------------------Worker scaling--------------------------------------------------------------------
-- 1, 2 and 4 workers, next to apply_mt. The leader
-- still hands N x M rows to the executor, which bounds the fast path
\echo "apply_mt_pw, 1 worker"
select count(*) from apply_mt_pw(
    lambda(a:[x:float, y:float, z:float],
           b:[f:(float,float->float),
              g:(float,float,float,(float,float->float)->float)])
      (b.g(a.x, a.y, a.z, b.f) + a.z),
    (select x, y, z from nums_smol),
    (select * from lambdas_table_helper),
    1, 1);

\echo "apply_mt_pw, 2 workers"
select count(*) from apply_mt_pw(
    lambda(a:[x:float, y:float, z:float],
           b:[f:(float,float->float),
              g:(float,float,float,(float,float->float)->float)])
      (b.g(a.x, a.y, a.z, b.f) + a.z),
    (select x, y, z from nums_smol),
    (select * from lambdas_table_helper),
    2, 1);

\echo "apply_mt_pw, 4 workers"
select count(*) from apply_mt_pw(
    lambda(a:[x:float, y:float, z:float],
           b:[f:(float,float->float),
              g:(float,float,float,(float,float->float)->float)])
      (b.g(a.x, a.y, a.z, b.f) + a.z),
    (select x, y, z from nums_smol),
    (select * from lambdas_table_helper),
    4, 1);

\echo "apply_mt (threads), 4 threads"
select count(*) from apply_mt(
    lambda(a:[x:float, y:float, z:float],
           b:[f:(float,float->float),
              g:(float,float,float,(float,float->float)->float)])
      (b.g(a.x, a.y, a.z, b.f) + a.z),
    (select x, y, z from nums_smol),
    (select * from lambdas_table_helper),
    4, 0);

-- the same sweep interpreted (apply_mt cannot run it); expect one jit-off
-- warning per lambda per worker
set jit='off';
set client_min_messages = error;

\echo "apply_mt_pw interpreted (mode 0), 1 worker"
select count(*) from apply_mt_pw(
    lambda(a:[x:float, y:float, z:float],
           b:[f:(float,float->float),
              g:(float,float,float,(float,float->float)->float)])
      (b.g(a.x, a.y, a.z, b.f) + a.z),
    (select x, y, z from nums_smol),
    (select * from lambdas_table_helper),
    1, 0);

\echo "apply_mt_pw interpreted (mode 0), 2 workers"
select count(*) from apply_mt_pw(
    lambda(a:[x:float, y:float, z:float],
           b:[f:(float,float->float),
              g:(float,float,float,(float,float->float)->float)])
      (b.g(a.x, a.y, a.z, b.f) + a.z),
    (select x, y, z from nums_smol),
    (select * from lambdas_table_helper),
    2, 0);

\echo "apply_mt_pw interpreted (mode 0), 4 workers"
select count(*) from apply_mt_pw(
    lambda(a:[x:float, y:float, z:float],
           b:[f:(float,float->float),
              g:(float,float,float,(float,float->float)->float)])
      (b.g(a.x, a.y, a.z, b.f) + a.z),
    (select x, y, z from nums_smol),
    (select * from lambdas_table_helper),
    4, 0);

set jit='on';
reset client_min_messages;

\timing off

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
