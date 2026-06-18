\set ON_ERROR_STOP on
\pset pager off

SELECT setseed(0.42);

-- Avoid generic plans
SET plan_cache_mode = force_custom_plan;

-- keep output stable-ish
SET client_min_messages = notice;

--debugger pid print
select pg_backend_pid();
\pset pager off

--meta flags, jit needs to be on, 'load llvm' loads dependencies
set jit='on';
load 'llvmjit.so';

--drop all tables, to create new ones
drop table if exists nums_smol;

------------------------------------------create new tables and fill them with usable data----------------------------------------------
create UNLOGGED table nums_smol(x float not null, y float not null, z float not null, a float not null, b float not null, c float not null, d float not null);

insert into nums_smol (x, y, z, a, b, c, d)
select
    random()::float AS x,
    random()::float AS y,
    random()::float AS z,
    random()::float AS a,
    random()::float AS b,
    random()::float AS c,
    random()::float AS d
from generate_series(1, 100000);
----------------------------------------------------------------------------------------------------------------------------------------

--------------------------------------------------------- load functions -----------------------------------------------------------
create or replace function apply_timing("lambda", lambdatable, lambdatable, int, int)
returns setof record
as '$libdir/apply_timing_ext.so','apply_timing'
language C STRICT;
----------------------------------------------------------------------------------------------------------------------------------------

------------------------------------------------------Test Higher-Order Lambdas---------------------------------------------------------
-- Drop old tables to make space for new ones
drop table if exists lambdas_order_1;
drop table if exists lambdas_order_2;
drop table if exists lambdas_table_helper;

-- First-Order Lambda Table (signature on the column)
create table lambdas_order_1 (
    f lambda(float8, float8 -> float8) not null,
    description TEXT
);

-- Second-Order Lambda Table (higher-order: takes the first-order f as a parameter)
create table lambdas_order_2 (
    g lambda(float8, float8, float8, (float8, float8 -> float8) -> float8) not null,
    description TEXT
);

-- First-Order Lambdas (float, float → float)
insert into lambdas_order_1 values
(lambda(x, y)(log(x + 1.0) + exp(y)), 'First-Order: Log-Exp transform'),
(lambda(x, y)(abs(x - y)), 'First-Order: Absolute difference'),
(lambda(x, y)(x^2 + y^2), 'First-Order: Euclidean norm squared'),
(lambda(x, y)(exp(x/10.0) + exp(y/10.0)), 'First-Order: Exp-Check');

-- Second-Order Lambdas
insert into lambdas_order_2 values
(lambda(x, y, z, f)(f(x, y) * z), 'Second-Order: Weighted lambda eval'),
-- (lambda(x, y, z, f)(f(y, y) - f(z, z)), 'Second-Order: Diagonal diff'),
-- (lambda(x, y, z, f)(f(x + z, y) + sin(z)), 'Second-Order: Lambda + sine mod'),
(lambda(x, y, z, f)(z * f(y, x)^2), 'Second-Order: Quadratic lambda eval'),
(lambda(x, y, z, f)(f(x, y) - exp(z/10.0)), 'Second-Order: Exp-Check');

-- disable debugging
set custom_lambda_debugging_var TO off;

-- create temp_table for clarity
create table lambdas_table_helper as
select f, g
from lambdas_order_1 cross join lambdas_order_2;

ANALYZE;

-- =====================================================================
-- Run 10x each step
-- =====================================================================
DO $$
DECLARE
  run_ctr  int;
  ndata    int;
  sql text;
  nthreads int := 34;
  queue_cap int := 0;
BEGIN
  FOREACH ndata IN ARRAY ARRAY[10000, 20000, 30000, 40000, 50000, 60000, 70000, 80000, 90000, 100000] LOOP
    FOR run_ctr IN 1..10 LOOP
      DISCARD PLANS;
      sql := format($fmt$
        SELECT count(*) FROM apply_timing(
          lambda(a:[x:float, y:float, z:float],
                 b:[f:(float,float->float),
                    g:(float,float,float,(float,float->float)->float)])
            (b.g(a.x, a.y, a.z, b.f) + a.z),
          (SELECT * FROM nums_smol LIMIT %s),
          (SELECT * FROM lambdas_table_helper),
          %s,
          %s
        );
      $fmt$, ndata, nthreads, queue_cap);

      RAISE NOTICE 'RUN #%, ndata=%, nthreads=%, queuecap=%',
                   run_ctr, ndata, nthreads, queue_cap;

      EXECUTE sql;

    END LOOP;
  END LOOP;
END $$;