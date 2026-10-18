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
drop table if exists nums;
drop table if exists nums_short;
drop table if exists nums_numeric;
drop table if exists nums_label;
drop table if exists nums_null;
drop table if exists points;
drop table if exists pages;
drop table if exists nums_matrix;
drop table if exists nums_matrix_test;
drop table if exists nums_large;
drop table if exists nums_smol;

------------------------------------------create new tables and fill them with usable data----------------------------------------------
create table nums(x float not null, y float not null, z float not null, a float not null, b float not null, c float not null, d float not null);
create table nums_short(x float not null, y float not null, z float not null, a float not null, b float not null, c float not null, d float not null);
create table nums_numeric(x float not null, y float not null, z float not null);
create table nums_label(x float not null, y float not null, z float not null);
create table nums_null(x float, y float);
create table nums_matrix(x double precision array not null, y double precision array not null, a double precision array not null, b double precision array not null);
create table nums_matrix_test(x double precision array not null, y double precision array not null);
create table points(x float not null, y float not null);
create table pages(src float not null, dst float not null, tmp_x float not null, tmp_y float not null);
create table nums_large(x1 float not null, y1 float not null, z1 float not null, x2 float not null, y2 float not null, z2 float not null, x3 float not null, y3 float not null, z3 float not null);
create table nums_smol(x float not null, y float not null, z float not null, a float not null, b float not null, c float not null, d float not null);

insert into nums select generate_series(1, 100), generate_series(101, 200), generate_series(201, 300), generate_series(1, 100), generate_series(1, 100), generate_series(1, 100), generate_series(1, 100);
insert into nums_short select generate_series(1, 5), generate_series(101, 105), generate_series(201, 205), generate_series(1, 5), generate_series(1, 5), generate_series(1, 5), generate_series(1, 5);
insert into nums_numeric select generate_series(-2, -2), generate_series(5, 5), generate_series(12, 12);
insert into nums_label select generate_series(2, 2), generate_series(4, 4), generate_series(5, 5);
insert into nums_matrix values ('{{2,-4}, {6,8}, {2,2}}', '{{8,4,-2, 1}, {4,2,1, 1}}', '{{1,2,3,4,5}, {1,2,3,4,5}, {1,2,3,4,5}, {1,2,3,4,5}}', '{{1,2}, {1,2}, {1,2}, {1,2}, {1,2}}');
insert into nums_matrix_test values ('{{2,-4}, {6,8}, {2,2}}', '{{2,-4}, {6,8}, {2,2}}');
insert into nums_large select generate_series(1,10000), generate_series(10001,20000), generate_series(20001,30000), generate_series(1,10000), generate_series(10001,20000), generate_series(20001,30000), generate_series(1,10000), generate_series(10001,20000), generate_series(20001,30000);
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

insert into nums_null select generate_series(1, 1), generate_series(2, 2);
insert into nums_null select 1 as x, null as y;

insert into points select generate_series(1, 100), generate_series(101, 200);
insert into pages select generate_series(0.1, 1), generate_series(0.1, 1), generate_series(0.1, 1), generate_series(0.1, 1);
----------------------------------------------------------------------------------------------------------------------------------------


--------------------------------------------------------- load all functions -----------------------------------------------------------
create or replace function label(lambdacursor, "lambda") 
returns setof record
as '$libdir/../../../src/ext/lambda_ext.so','label'
language C STRICT;

create or replace function label_fast(lambdatable, "lambda") 
returns setof record
as '$libdir/../../../src/ext/lambda_ext.so','label_fast'
language C STRICT;

create or replace function kmeans_v2(lambdatable, lambdatable, "lambda", int, int) 
returns setof record
as '$libdir/../../../src/ext/kmeans_v2_ext.so','kmeans_v2'
language C STRICT;

-- Returns: Datatable(tables[0]), Lambdatable(tables[1]), "applied_lambda", "result"
create or replace function apply_l1_2("lambda", lambdatable, lambdatable, boolean)
returns setof record
as '$libdir/../../../src/ext/apply_ext.so','apply_l1_2'
language C STRICT;

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
drop table if exists lambdas_order_1;
drop table if exists lambdas_order_2;
drop table if exists lambdas_table_helper;

-- First-Order Lambda Table
create table lambdas_order_1 (
    f lambda(float8, float8 -> float8) not null,
    description TEXT
);

-- Second-Order Lambda Table
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

-- inserted lambdas
-- select * from lambdas_order_1;
-- select * from lambdas_order_2;

-- Enable debugging
set custom_lambda_debugging_var TO on;

-- create temp_table for clarity
create table lambdas_table_helper as
select f, g
from lambdas_order_1 cross join lambdas_order_2;

-- Third-Order: Apply and subtract interaction term
-- select x, y, z, applied_lambda, result from apply_l1_2(
--     lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])
--     (b.g(a.x, a.y, a.z, b.f) - 2*a.x*a.y),
--     (select * from nums_short),
--     (select * from lambdas_table_helper),
--     false
-- );

-- -- Third-Order: Swapped inputs with interaction
-- select x, y, z, applied_lambda, result from apply_l1_2(
--     lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])
--     (b.g(a.z, a.x, a.y, b.f) + a.x * a.z),
--     (select * from nums_short),
--     (select * from lambdas_table_helper),
--     false
-- );

-- -- Third-Order: Shift inputs, halve result
-- select x, y, z, applied_lambda, result from apply_l1_2(
--     lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])
--     (b.g(a.x + 1, a.y + 1, a.z + 1, b.f) / 2.0),
--     (select * from nums_short),
--     (select * from lambdas_table_helper),
--     false
-- );

-- -- Third-Order: Apply and add sine modulation
-- select x, y, z, applied_lambda, result from apply_l1_2(
--     lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])
--     (b.g(a.x, a.y, a.z, b.f) + sin(a.x + a.y)),
--     (select * from nums_short),
--     (select * from lambdas_table_helper),
--     false
-- );

-- -- Third-Order: Square second-order output and subtract base lambda
-- select x, y, z, applied_lambda, result from apply_l1_2(
--     lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])
--     (b.g(a.y, a.z, a.x, b.f)^2 - b.f(a.x, a.y)),
--     (select * from nums_short),
--     (select * from lambdas_table_helper),
--     false
-- );

-- -- Third-Order: Log-transform the lambda output
-- select x, y, z, applied_lambda, result from apply_l1_2(
--     lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])
--     (log(b.g(a.x, a.x, a.z, b.f) + 1.0)),
--     (select * from nums_short),
--     (select * from lambdas_table_helper),
--     false
-- );

-- -- Third-Order: Scaled inputs and additive bias
-- select x, y, z, applied_lambda, result from apply_l1_2(
--     lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])
--     (b.g(a.x * 2, a.y / 2, a.z, b.f) + a.z),
--     (select * from nums_short),
--     (select * from lambdas_table_helper),
--     false
-- );

-- -- Third-Order: Absolute root post-processing
-- select x, y, z, applied_lambda, result from apply_l1_2(
--     lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])
--     (sqrt(abs(b.g(a.x, a.y, a.z, b.f))) - a.x*a.y),
--     (select * from nums_short),
--     (select * from lambdas_table_helper),
--     false
-- );
----------------------------------------------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------------------------
--testing multhtreading
-- set jit = 'on';
-- EXPLAIN (ANALYZE, BUFFERS, TIMING, VERBOSE, SUMMARY) 
-- --select * from apply_mt(
-- select * from apply_timing(    
--     lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])
--     (b.g(a.x, a.y, a.z, b.f) + a.z),
--     (select * from nums_smol),
--     (select * from lambdas_table_helper),
--     12,              --nthreads
--     0              --queue_capacity
-- );

-- set jit = 'on';
-- EXPLAIN (ANALYZE, BUFFERS, TIMING, VERBOSE, SUMMARY) 
-- --select * from apply_mt(
-- select * from apply_mt_agg(    
--     lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])
--     (b.g(a.x, a.y, a.z, b.f) + a.z),
--     (select * from nums_smol),
--     (select * from lambdas_table_helper),
--     12,              --nthreads
--     0              --queue_capacity
-- );

-- create temp_table for clarity
-- drop table if exists lambdas_table_helper_baseline;
-- create table lambdas_table_helper_baseline(f "lambda" not null);

-- insert into lambdas_table_helper_baseline values
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])(a.x * 5 + a.y - a.z)),
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])((a.x + a.y + a.z) / 3)),
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])(sqrt(a.x * a.x + a.y * a.y + a.z * a.z))),
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])(power(a.x, 2) + power(a.y, 2) - power(a.z, 2))),
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])(abs(a.x - a.y) + abs(a.y - a.z))),
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])(ln(a.x + 1.0) - ln(a.y + 1.0) + ln(a.z + 1.0))),
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])(sin(a.x) * cos(a.y) + sin(a.z))),
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])(exp(a.x / 10.0) + exp(a.y / 10.0) - exp(a.z / 10.0) + a.z));

-- select * from apply_mt_baseline(
--     lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])
--     (1.0::float8),
--     (select * from nums_smol),
--     (select * from lambdas_table_helper_baseline),
--     12,              --nthreads
--     512              --queue_capacity
-- );

----------------------------------------------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------------------------------------------
--testing kmeans_higher-order
-- set jit = 'on';
-- EXPLAIN (ANALYZE, BUFFERS, TIMING, VERBOSE, SUMMARY) 
-- --select * from apply_mt(
-- select * from apply_timing(    
--     lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])
--     (b.g(a.x, a.y, a.z, b.f) + a.z),
--     (select * from nums_smol),
--     (select * from lambdas_table_helper),
--     12,              --nthreads
--     0              --queue_capacity
-- );

-- set jit = 'on';
-- EXPLAIN (ANALYZE, BUFFERS, TIMING, VERBOSE, SUMMARY) 
-- --select * from apply_mt(
-- select * from apply_mt_agg(    
--     lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])
--     (b.g(a.x, a.y, a.z, b.f) + a.z),
--     (select * from nums_smol),
--     (select * from lambdas_table_helper),
--     12,              --nthreads
--     0              --queue_capacity
-- );

-- create temp_table for clarity
-- drop table if exists lambdas_table_helper_baseline;
-- create table lambdas_table_helper_baseline(f "lambda" not null);

-- insert into lambdas_table_helper_baseline values
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])(a.x * 5 + a.y - a.z)),
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])((a.x + a.y + a.z) / 3)),
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])(sqrt(a.x * a.x + a.y * a.y + a.z * a.z))),
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])(power(a.x, 2) + power(a.y, 2) - power(a.z, 2))),
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])(abs(a.x - a.y) + abs(a.y - a.z))),
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])(ln(a.x + 1.0) - ln(a.y + 1.0) + ln(a.z + 1.0))),
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])(sin(a.x) * cos(a.y) + sin(a.z))),
-- (lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])(exp(a.x / 10.0) + exp(a.y / 10.0) - exp(a.z / 10.0) + a.z));

-- select * from apply_mt_baseline(
--     lambda(a:[x:float, y:float, z:float], b:[f:(float,float->float), g:(float,float,float,(float,float->float)->float)])
--     (1.0::float8),
--     (select * from nums_smol),
--     (select * from lambdas_table_helper_baseline),
--     12,              --nthreads
--     512              --queue_capacity
-- );

----------------------------------------------------------------------------------------------------------------------------------------
-- Disable debugging
set custom_lambda_debugging_var TO off;
\set ECHO none
\pset pager on
----------------------------------------------------------------------------------------------------------------------------------------
