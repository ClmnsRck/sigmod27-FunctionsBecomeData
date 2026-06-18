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
from generate_series(1, 10);

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

--parameters: inputtable(weights and data combined), lambdafunction, iterations, num attrs, batch size(if 0 or lower, BGD will be done, otherwise mini-batchGD), learning_rate
-- Returns: Datatable(tables[0]), Lambdatable(tables[1]), "applied_lambda", "result"
create or replace function apply_mt("lambda", lambdatable, lambdatable, int, int)
returns setof record
as '$libdir/../../../src/ext/apply_mt_ext.so','apply_mt'
language C STRICT;

create or replace function apply_timing("lambda", lambdatable, lambdatable, int, int)
returns setof record
as '$libdir/../../../src/ext/apply_timing_ext.so','apply_timing'
language C STRICT;

create or replace function apply_mt_agg("lambda", lambdatable, lambdatable, int, int)
returns setof record
as '$libdir/../../../src/ext/apply_mt_agg_ext.so','apply_mt_agg'
language C STRICT;
----------------------------------------------------------------------------------------------------------------------------------------

------------------------------------------------------Setup and Misc--------------------------------------------------------------------
-- \set ECHO all
----------------------------------------------------------------------------------------------------------------------------------------

------------------------------------------------------Test Higher-Order Lambdas---------------------------------------------------------
-- set jit = 'off';
-- set jit_above_cost = -1;             --stop jit-usage
-- set jit_inline_above_cost = -1;      --stop jit-usage
-- set jit_optimize_above_cost = -1;    --stop jit-usage

-- -- Drop old tables to make space for new ones
-- drop table if exists lambdas;
-- drop table if exists lambdas_ho;
-- drop table if exists lambdas_same;

-- \echo "------------------------------------------------------------------------------------------------------------------------------"

-- -- First-Order Lambda Table
-- create table lambdas (
--     f lambda(float8, float8 -> float8) not null,
--     description TEXT
-- );
-- -- Higher-Order lambdas
-- create table lambdas_ho (
--     g lambda(float8, float8, float8, (float8, float8 -> float8) -> float8) not null,
--     description text
-- );
-- -- Check reusable signatures
-- create table lambdas_same (
--     h lambda(float8, float8 -> float8) not null,
--     description TEXT
-- );

-- \echo "------------------------------------------------------------------------------------------------------------------------------"

-- -- Sanity Check, wether the signature was stored correctly
-- SELECT
--     c.relname AS table_name,
--     a.attname AS column_name,
--     a.atttypmod AS typmod,
--     s.lamsigsrc
-- FROM pg_attribute a
-- JOIN pg_class c
--   ON c.oid = a.attrelid
-- JOIN pg_lambdasig s
--   ON s.lamsigid = a.atttypmod
-- WHERE a.atttypid = 'pg_catalog.lambda'::regtype
--   AND a.attnum > 0
--   AND NOT a.attisdropped
-- ORDER BY c.relname, a.attnum;

-- \echo "------------------------------------------------------------------------------------------------------------------------------"

-- -- First-Order Lambdas (float, float → float)
-- insert into lambdas values
-- (lambda(x, y)(log(x + 1.0) + exp(y)), 'First-Order: Log-Exp transform'),
-- (lambda(x, y)(abs(x - y)), 'First-Order: Absolute difference'),
-- (lambda(x, y)(x^2 + y^2), 'First-Order: Euclidean norm squared'),
-- (lambda(x, y)(exp(x/10.0) + exp(y/10.0)), 'First-Order: Exp-Check'),
-- (lambda(x, y)(x + y), 'First-Order: Sanity Check(x + y)');

-- \echo "------------------------------------------------------------------------------------------------------------------------------"

-- -- Second Order Lambdas (f, f, f, (f, f -> f) -> f)
-- insert into lambdas_ho values
-- (lambda(a, b, scale, op)(scale * op(a, b)), 'HO: scale binary lambda result'),
-- (lambda(a, b, myoffset, op)(op(a, b) + myoffset), 'HO: offset binary lambda result'),
-- (lambda(a, b, myweights, op)((myweights * op(a, b)) + ((1.0 - myweights) * a)), 'HO: weighted mix of op result and first input'),
-- (lambda(a, b, divisor, op)(op(a, b) * divisor), 'HO: multiplication'),
-- (lambda(a, b, c, op)(c + op(a, b)), 'HO: Sanity check(+)');

-- \echo "------------------------------------------------------------------------------------------------------------------------------"

-- -- inserted lambdas
-- select * from lambdas;
-- select * from lambdas_ho;

-- \echo "------------------------------------------------------------------------------------------------------------------------------"

-- -- test first-order lambdas outside of UDFs
-- select ns.x, ns.y, l.f(ns.x, ns.y) as result, l.description
-- from nums_smol ns, lambdas l;

-- \echo "------------------------------------------------------------------------------------------------------------------------------"

-- -- test higher-order lambdas outside of UDFs
-- select ns.x, ns.y, ns.z, lho.g(ns.x, ns.y, ns.z, l.f) as result, l.description, lho.description
-- from lambdas l, lambdas_ho lho, nums_smol ns;

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- Enable debugging
set custom_lambda_debugging_var TO on;
----------------------------------------------------------------------------------------------------------------------------------------
--Check for Correctness
--Check for Correctness
drop table if exists lambda_c;
drop table if exists lambdas_ho_c;
drop table if exists lambdas_hoho_c;
drop table if exists numbers_c;
drop table if exists lambda_expected_c;

create table lambda_c (
    f lambda(float8, float8 -> float8),
    description text
);

create table lambdas_ho_c (
    g lambda(float8, float8, float8, (float8, float8 -> float8) -> float8),
    description text
);

create table lambdas_hoho_c (
    h lambda(
        float8,
        float8,
        float8,
        (float8, float8 -> float8),
        (float8, float8, float8, (float8, float8 -> float8) -> float8)
        -> float8
    ),
    description text
);

create table numbers_c (
    x float8,
    y float8,
    z float8
);

create table lambda_expected_c (
    x float8,
    y float8,
    z float8,
    lambda_description text,
    ho_description text,
    hoho_description text,
    expected float8
);

insert into lambda_c values
(lambda(x, y)(x + y), 'FO: add'),
(lambda(x, y)(x - y), 'FO: subtract'),
(lambda(x, y)(x * y), 'FO: multiply');

insert into lambdas_ho_c values
(lambda(a, b, c, op)(c + op(a, b)), 'HO: c plus op'),
(lambda(a, b, c, op)(c * op(a, b)), 'HO: c times op'),
(lambda(a, b, c, op)(op(a, b) - c), 'HO: op minus c');

insert into lambdas_hoho_c values
(lambda(a, b, c, op, hop)(hop(a, b, c, op) + 1.0), 'HOHO: ho plus one'),
(lambda(a, b, c, op, hop)(2.0 * hop(a, b, c, op)), 'HOHO: twice ho'),
(lambda(a, b, c, op, hop)(hop(a, b, c, op) - op(a, b)), 'HOHO: ho minus op');

insert into numbers_c values
(1.0, 2.0, 10.0),
(3.0, 4.0, 0.5),
(-1.0, 5.0, 2.0);

insert into lambda_expected_c values
-- x, y, z, lambda_description, ho_description, hoho_description, expected

-- n=(1,2,10), FO add op=3
(1.0, 2.0, 10.0, 'FO: add', 'HO: c plus op',  'HOHO: ho plus one', 14.0),
(1.0, 2.0, 10.0, 'FO: add', 'HO: c plus op',  'HOHO: twice ho', 26.0),
(1.0, 2.0, 10.0, 'FO: add', 'HO: c plus op',  'HOHO: ho minus op', 10.0),
(1.0, 2.0, 10.0, 'FO: add', 'HO: c times op', 'HOHO: ho plus one', 31.0),
(1.0, 2.0, 10.0, 'FO: add', 'HO: c times op', 'HOHO: twice ho', 60.0),
(1.0, 2.0, 10.0, 'FO: add', 'HO: c times op', 'HOHO: ho minus op', 27.0),
(1.0, 2.0, 10.0, 'FO: add', 'HO: op minus c', 'HOHO: ho plus one', -6.0),
(1.0, 2.0, 10.0, 'FO: add', 'HO: op minus c', 'HOHO: twice ho', -14.0),
(1.0, 2.0, 10.0, 'FO: add', 'HO: op minus c', 'HOHO: ho minus op', -10.0),

-- n=(1,2,10), FO subtract op=-1
(1.0, 2.0, 10.0, 'FO: subtract', 'HO: c plus op',  'HOHO: ho plus one', 10.0),
(1.0, 2.0, 10.0, 'FO: subtract', 'HO: c plus op',  'HOHO: twice ho', 18.0),
(1.0, 2.0, 10.0, 'FO: subtract', 'HO: c plus op',  'HOHO: ho minus op', 10.0),
(1.0, 2.0, 10.0, 'FO: subtract', 'HO: c times op', 'HOHO: ho plus one', -9.0),
(1.0, 2.0, 10.0, 'FO: subtract', 'HO: c times op', 'HOHO: twice ho', -20.0),
(1.0, 2.0, 10.0, 'FO: subtract', 'HO: c times op', 'HOHO: ho minus op', -9.0),
(1.0, 2.0, 10.0, 'FO: subtract', 'HO: op minus c', 'HOHO: ho plus one', -10.0),
(1.0, 2.0, 10.0, 'FO: subtract', 'HO: op minus c', 'HOHO: twice ho', -22.0),
(1.0, 2.0, 10.0, 'FO: subtract', 'HO: op minus c', 'HOHO: ho minus op', -10.0),

-- n=(1,2,10), FO multiply op=2
(1.0, 2.0, 10.0, 'FO: multiply', 'HO: c plus op',  'HOHO: ho plus one', 13.0),
(1.0, 2.0, 10.0, 'FO: multiply', 'HO: c plus op',  'HOHO: twice ho', 24.0),
(1.0, 2.0, 10.0, 'FO: multiply', 'HO: c plus op',  'HOHO: ho minus op', 10.0),
(1.0, 2.0, 10.0, 'FO: multiply', 'HO: c times op', 'HOHO: ho plus one', 21.0),
(1.0, 2.0, 10.0, 'FO: multiply', 'HO: c times op', 'HOHO: twice ho', 40.0),
(1.0, 2.0, 10.0, 'FO: multiply', 'HO: c times op', 'HOHO: ho minus op', 18.0),
(1.0, 2.0, 10.0, 'FO: multiply', 'HO: op minus c', 'HOHO: ho plus one', -7.0),
(1.0, 2.0, 10.0, 'FO: multiply', 'HO: op minus c', 'HOHO: twice ho', -16.0),
(1.0, 2.0, 10.0, 'FO: multiply', 'HO: op minus c', 'HOHO: ho minus op', -10.0),

-- n=(3,4,0.5), FO add op=7
(3.0, 4.0, 0.5, 'FO: add', 'HO: c plus op',  'HOHO: ho plus one', 8.5),
(3.0, 4.0, 0.5, 'FO: add', 'HO: c plus op',  'HOHO: twice ho', 15.0),
(3.0, 4.0, 0.5, 'FO: add', 'HO: c plus op',  'HOHO: ho minus op', 0.5),
(3.0, 4.0, 0.5, 'FO: add', 'HO: c times op', 'HOHO: ho plus one', 4.5),
(3.0, 4.0, 0.5, 'FO: add', 'HO: c times op', 'HOHO: twice ho', 7.0),
(3.0, 4.0, 0.5, 'FO: add', 'HO: c times op', 'HOHO: ho minus op', -3.5),
(3.0, 4.0, 0.5, 'FO: add', 'HO: op minus c', 'HOHO: ho plus one', 7.5),
(3.0, 4.0, 0.5, 'FO: add', 'HO: op minus c', 'HOHO: twice ho', 13.0),
(3.0, 4.0, 0.5, 'FO: add', 'HO: op minus c', 'HOHO: ho minus op', -0.5),

-- n=(3,4,0.5), FO subtract op=-1
(3.0, 4.0, 0.5, 'FO: subtract', 'HO: c plus op',  'HOHO: ho plus one', 0.5),
(3.0, 4.0, 0.5, 'FO: subtract', 'HO: c plus op',  'HOHO: twice ho', -1.0),
(3.0, 4.0, 0.5, 'FO: subtract', 'HO: c plus op',  'HOHO: ho minus op', 0.5),
(3.0, 4.0, 0.5, 'FO: subtract', 'HO: c times op', 'HOHO: ho plus one', 0.5),
(3.0, 4.0, 0.5, 'FO: subtract', 'HO: c times op', 'HOHO: twice ho', -1.0),
(3.0, 4.0, 0.5, 'FO: subtract', 'HO: c times op', 'HOHO: ho minus op', 0.5),
(3.0, 4.0, 0.5, 'FO: subtract', 'HO: op minus c', 'HOHO: ho plus one', -0.5),
(3.0, 4.0, 0.5, 'FO: subtract', 'HO: op minus c', 'HOHO: twice ho', -3.0),
(3.0, 4.0, 0.5, 'FO: subtract', 'HO: op minus c', 'HOHO: ho minus op', -0.5),

-- n=(3,4,0.5), FO multiply op=12
(3.0, 4.0, 0.5, 'FO: multiply', 'HO: c plus op',  'HOHO: ho plus one', 13.5),
(3.0, 4.0, 0.5, 'FO: multiply', 'HO: c plus op',  'HOHO: twice ho', 25.0),
(3.0, 4.0, 0.5, 'FO: multiply', 'HO: c plus op',  'HOHO: ho minus op', 0.5),
(3.0, 4.0, 0.5, 'FO: multiply', 'HO: c times op', 'HOHO: ho plus one', 7.0),
(3.0, 4.0, 0.5, 'FO: multiply', 'HO: c times op', 'HOHO: twice ho', 12.0),
(3.0, 4.0, 0.5, 'FO: multiply', 'HO: c times op', 'HOHO: ho minus op', -6.0),
(3.0, 4.0, 0.5, 'FO: multiply', 'HO: op minus c', 'HOHO: ho plus one', 12.5),
(3.0, 4.0, 0.5, 'FO: multiply', 'HO: op minus c', 'HOHO: twice ho', 23.0),
(3.0, 4.0, 0.5, 'FO: multiply', 'HO: op minus c', 'HOHO: ho minus op', -0.5),

-- n=(-1,5,2), FO add op=4
(-1.0, 5.0, 2.0, 'FO: add', 'HO: c plus op',  'HOHO: ho plus one', 7.0),
(-1.0, 5.0, 2.0, 'FO: add', 'HO: c plus op',  'HOHO: twice ho', 12.0),
(-1.0, 5.0, 2.0, 'FO: add', 'HO: c plus op',  'HOHO: ho minus op', 2.0),
(-1.0, 5.0, 2.0, 'FO: add', 'HO: c times op', 'HOHO: ho plus one', 9.0),
(-1.0, 5.0, 2.0, 'FO: add', 'HO: c times op', 'HOHO: twice ho', 16.0),
(-1.0, 5.0, 2.0, 'FO: add', 'HO: c times op', 'HOHO: ho minus op', 4.0),
(-1.0, 5.0, 2.0, 'FO: add', 'HO: op minus c', 'HOHO: ho plus one', 3.0),
(-1.0, 5.0, 2.0, 'FO: add', 'HO: op minus c', 'HOHO: twice ho', 4.0),
(-1.0, 5.0, 2.0, 'FO: add', 'HO: op minus c', 'HOHO: ho minus op', -2.0),

-- n=(-1,5,2), FO subtract op=-6
(-1.0, 5.0, 2.0, 'FO: subtract', 'HO: c plus op',  'HOHO: ho plus one', -3.0),
(-1.0, 5.0, 2.0, 'FO: subtract', 'HO: c plus op',  'HOHO: twice ho', -8.0),
(-1.0, 5.0, 2.0, 'FO: subtract', 'HO: c plus op',  'HOHO: ho minus op', 2.0),
(-1.0, 5.0, 2.0, 'FO: subtract', 'HO: c times op', 'HOHO: ho plus one', -11.0),
(-1.0, 5.0, 2.0, 'FO: subtract', 'HO: c times op', 'HOHO: twice ho', -24.0),
(-1.0, 5.0, 2.0, 'FO: subtract', 'HO: c times op', 'HOHO: ho minus op', -6.0),
(-1.0, 5.0, 2.0, 'FO: subtract', 'HO: op minus c', 'HOHO: ho plus one', -7.0),
(-1.0, 5.0, 2.0, 'FO: subtract', 'HO: op minus c', 'HOHO: twice ho', -16.0),
(-1.0, 5.0, 2.0, 'FO: subtract', 'HO: op minus c', 'HOHO: ho minus op', -2.0),

-- n=(-1,5,2), FO multiply op=-5
(-1.0, 5.0, 2.0, 'FO: multiply', 'HO: c plus op',  'HOHO: ho plus one', -2.0),
(-1.0, 5.0, 2.0, 'FO: multiply', 'HO: c plus op',  'HOHO: twice ho', -6.0),
(-1.0, 5.0, 2.0, 'FO: multiply', 'HO: c plus op',  'HOHO: ho minus op', 2.0),
(-1.0, 5.0, 2.0, 'FO: multiply', 'HO: c times op', 'HOHO: ho plus one', -9.0),
(-1.0, 5.0, 2.0, 'FO: multiply', 'HO: c times op', 'HOHO: twice ho', -20.0),
(-1.0, 5.0, 2.0, 'FO: multiply', 'HO: c times op', 'HOHO: ho minus op', -5.0),
(-1.0, 5.0, 2.0, 'FO: multiply', 'HO: op minus c', 'HOHO: ho plus one', -6.0),
(-1.0, 5.0, 2.0, 'FO: multiply', 'HO: op minus c', 'HOHO: twice ho', -14.0),
(-1.0, 5.0, 2.0, 'FO: multiply', 'HO: op minus c', 'HOHO: ho minus op', -2.0);

set jit='on';

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Actual vs expected"

select
    n.x,
    n.y,
    n.z,
    l.description as lambda_description,
    ho.description as ho_description,
    hoho.description as hoho_description,
    hoho.h(n.x, n.y, n.z, l.f, ho.g) as actual,
    e.expected,
    hoho.h(n.x, n.y, n.z, l.f, ho.g) - e.expected as diff
from numbers_c n, lambda_c l, lambdas_ho_c ho, lambdas_hoho_c hoho, lambda_expected_c e
where e.x = n.x
  and e.y = n.y
  and e.z = n.z
  and e.lambda_description = l.description
  and e.ho_description = ho.description
  and e.hoho_description = hoho.description
order by n.x, n.y, n.z, l.description, ho.description, hoho.description;

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Mismatches only; expected result is zero rows"

select *
from (
    select
        n.x,
        n.y,
        n.z,
        l.description as lambda_description,
        ho.description as ho_description,
        hoho.description as hoho_description,
        hoho.h(n.x, n.y, n.z, l.f, ho.g) as actual,
        e.expected,
        abs(hoho.h(n.x, n.y, n.z, l.f, ho.g) - e.expected) as abs_diff
    from numbers_c n, lambda_c l, lambdas_ho_c ho, lambdas_hoho_c hoho, lambda_expected_c e
    where e.x = n.x
      and e.y = n.y
      and e.z = n.z
      and e.lambda_description = l.description
      and e.ho_description = ho.description
      and e.hoho_description = hoho.description
) s
where abs_diff > 1e-9;

----------------------------------------------------------------------------------------------------------------------------------------
-- Disable debugging
set custom_lambda_debugging_var TO off;
\set ECHO none
\pset pager on
----------------------------------------------------------------------------------------------------------------------------------------
