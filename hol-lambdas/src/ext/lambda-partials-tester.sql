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

\echo "------------------------------------------------------------------------------------------------------------------------------"

set custom_lambda_debugging_var TO on;

----------------------------------------------------------------------------------------------------------------------------------------
-- Partial application of scalar (column-stored) lambdas
----------------------------------------------------------------------------------------------------------------------------------------
-- A partial application supplies SOME of a lambda's args and leaves the rest as
-- holes ("_"). The result is a new lambda whose signature is the held positions
-- -> the original return type.
--
--   base_lambdas.fn : lambda(float, (float -> float) -> float)   -- (scalar s, function op)
--     f(s, _)  holds op -> lambda((float -> float) -> float)     == held_op_target
--     f(_, op) holds s  -> lambda(float -> float)                == held_scalar_target
--
-- unary_helpers supplies concrete unary lambdas to fill the function input `op`.
drop table if exists unary_helpers;
drop table if exists base_lambdas;
drop table if exists held_op_target;
drop table if exists held_scalar_target;

create table unary_helpers(
    fn lambda(float -> float) not null,
    description text
);

create table base_lambdas(
    fn lambda(float, (float -> float) -> float) not null,
    description text
);

create table held_op_target(
    fn lambda((float -> float) -> float) not null,
    description text
);

create table held_scalar_target(
    fn lambda(float -> float) not null,
    description text
);

insert into unary_helpers values
(lambda(x)(x * x),   'unary: square'),
(lambda(x)(x + 1.0), 'unary: increment');

insert into base_lambdas values
(lambda(s, op)(op(s) + s),   'HO: op(s) plus s'),
(lambda(s, op)(op(s) * 2.0), 'HO: twice op(s)'),
(lambda(s, op)(op(s) - s),   'HO: op(s) minus s');

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Source lambdas to be partially applied"

select * from base_lambdas;
select * from unary_helpers;

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Test 1: hold the function input -- f(s, _) : (float -> float) -> float"

-- Supply the scalar, hole the function input -> closure with s = 2.0 baked in.
select b.description, b.fn(2.0, _) as residual
from base_lambdas b;

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Test 2: hold the scalar input -- f(_, op) : float -> float"

-- Supply the function input, hole the scalar -> closure with op = helper baked in.
select b.description, h.description, b.fn(_, h.fn) as residual
from base_lambdas b, unary_helpers h;

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Test 3: residual signatures must fit the target columns (insert-time type check)"

-- A correct residual signature inserts cleanly; a wrong one is rejected by the column.
insert into held_op_target select b.fn(2.0, _), b.description from base_lambdas b;
insert into held_scalar_target select b.fn(_, h.fn), b.description || ' / ' || h.description
from base_lambdas b, unary_helpers h;

select * from held_op_target;
select * from held_scalar_target;

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Test 4: staged application equals direct"

-- Direct f(2.0, h) vs. staged (store f(_, h), then call it with 2.0) must agree.
select
    b.description,
    h.description,
    b.fn(2.0, h.fn)                     as direct,
    t.fn(2.0)                           as staged,
    t.fn(2.0) - b.fn(2.0, h.fn)         as diff
from held_scalar_target t, base_lambdas b, unary_helpers h
where t.description = b.description || ' / ' || h.description
order by b.description, h.description;

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Test 5: held function input applied later"

-- held_op_target holds the function input; calling it with a helper must equal direct.
select
    t.description,
    h.description,
    t.fn(h.fn)                          as staged,
    b.fn(2.0, h.fn)                     as direct,
    t.fn(h.fn) - b.fn(2.0, h.fn)        as diff
from held_op_target t, base_lambdas b, unary_helpers h
where t.description = b.description
order by t.description, h.description;

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Test 6: threaded function input filled -- hole the scalar, fill op + threaded helper, round-trip"

-- threaded_lambdas.fn threads `helper` THROUGH the higher-order input `op` (body
-- op(helper, a)); helper is never called directly. Filling a threaded function input
-- bakes it into the residual as an embedded value. Tests 6-10 round-trip each residual:
-- store it, apply it later, and require it to equal the direct full application (diff = 0).
drop table if exists threaded_lambdas;
drop table if exists wrapper_ops;
drop table if exists residual_scalar_held;
drop table if exists residual_helper_held;
drop table if exists residual_op_held;
drop table if exists residual_stage1;
drop table if exists residual_stage2;

create table wrapper_ops(
    -- op(g, x) = g(x) + x
    fn lambda((float -> float), float -> float) not null,
    description text
);

create table threaded_lambdas(
    -- f(a, op, helper) = op(helper, a): op is called, helper is only threaded into it
    fn lambda(float, ((float -> float), float -> float), (float -> float) -> float) not null,
    description text
);

-- residual-signature columns for the round-trips below
create table residual_scalar_held(fn lambda(float -> float) not null, description text);
create table residual_helper_held(fn lambda((float -> float) -> float) not null, description text);
create table residual_op_held(fn lambda(((float -> float), float -> float) -> float) not null, description text);
create table residual_stage1(fn lambda(float, (float -> float) -> float) not null, description text);
create table residual_stage2(fn lambda((float -> float) -> float) not null, description text);

insert into wrapper_ops values
(lambda(g, x)(g(x) + x), 'HO-op: g(x) plus x');

insert into threaded_lambdas values
(lambda(a, op, helper)(op(helper, a)), 'threaded: op(helper, a)');

-- Sanity: full application. helper = square -> op(square, 3.0) = 3*3 + 3 = 12.
select t.description, o.description, h.description,
       t.fn(3.0, o.fn, h.fn) as full_apply
from threaded_lambdas t, wrapper_ops o, unary_helpers h;

-- Hole a, fill op + helper. Residual (float -> float) collapses to helper(a) + a.
insert into residual_scalar_held
select t.fn(_, o.fn, h.fn), h.description
from threaded_lambdas t, wrapper_ops o, unary_helpers h;

select r.description,
       r.fn(3.0)                            as staged,
       t.fn(3.0, o.fn, h.fn)                as direct,
       r.fn(3.0) - t.fn(3.0, o.fn, h.fn)    as diff
from residual_scalar_held r, threaded_lambdas t, wrapper_ops o, unary_helpers h
where r.description = h.description
order by r.description;

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Test 7: threaded helper held -- fill scalar + op, leave helper open, then supply it"

-- f(3.0, op, _): helper becomes the residual's open input -> ((float -> float)) -> float.
insert into residual_helper_held
select t.fn(3.0, o.fn, _), o.description
from threaded_lambdas t, wrapper_ops o;

select r.description, h.description,
       r.fn(h.fn)                           as staged,
       t.fn(3.0, o.fn, h.fn)                as direct,
       r.fn(h.fn) - t.fn(3.0, o.fn, h.fn)   as diff
from residual_helper_held r, threaded_lambdas t, wrapper_ops o, unary_helpers h
order by h.description;

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Test 8: op held, threaded helper filled -- residual carries the helper as an embedded lambda"

-- f(3.0, _, helper): op held, so op(helper, 3.0) survives as a residual call whose first
-- arg is the filled helper, baked in as an embedded lambda. Supplying op inlines it and
-- resolves the embedded helper (the case the unified injector was extended for).
insert into residual_op_held
select t.fn(3.0, _, h.fn), h.description
from threaded_lambdas t, unary_helpers h;

select r.description,
       r.fn(o.fn)                           as staged,
       t.fn(3.0, o.fn, h.fn)                as direct,
       r.fn(o.fn) - t.fn(3.0, o.fn, h.fn)   as diff
from residual_op_held r, threaded_lambdas t, wrapper_ops o, unary_helpers h
where r.description = h.description
order by r.description;

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Test 9: two-stage partial -- apply, store, then partially apply the stored residual again"

-- Stage 1: f(_, op, _) holds a + helper -> (float, (float -> float)) -> float.
-- Stage 2: that residual, r(3.0, _), holds helper -> ((float -> float)) -> float.
insert into residual_stage1
select t.fn(_, o.fn, _), o.description
from threaded_lambdas t, wrapper_ops o;

insert into residual_stage2
select s.fn(3.0, _), 'stage2: ' || s.description
from residual_stage1 s;

select r.description, h.description,
       r.fn(h.fn)                           as staged2,
       t.fn(3.0, o.fn, h.fn)                as direct,
       r.fn(h.fn) - t.fn(3.0, o.fn, h.fn)   as diff
from residual_stage2 r, threaded_lambdas t, wrapper_ops o, unary_helpers h
order by h.description;

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Test 10: all arguments held -- a fully open partial must behave like the mother"

-- f(_, _) holds every argument; the residual matches f's signature. Reuses residual_stage1.
insert into residual_stage1
select b.fn(_, _), 'identity: ' || b.description
from base_lambdas b;

select r.description, h.description,
       r.fn(2.0, h.fn)                      as staged,
       b.fn(2.0, h.fn)                      as direct,
       r.fn(2.0, h.fn) - b.fn(2.0, h.fn)    as diff
from residual_stage1 r, base_lambdas b, unary_helpers h
where r.description = 'identity: ' || b.description
order by r.description, h.description;

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Test 11: constant folding -- residual with a foldable constant subexpression around a held call"

-- f(2.0, _) bakes s = 2.0, leaving op(2.0) + (2.0*10.0 - 5.0); the constant subtree
-- folds to op(2.0) + 15.0 (see the "Const Folding" debug dump). Folding must keep the
-- held call intact and preserve the result -- staged must equal direct.
drop table if exists fold_base;
drop table if exists residual_fold;

create table fold_base(
    fn lambda(float, (float -> float) -> float) not null,
    description text
);
create table residual_fold(fn lambda((float -> float) -> float) not null, description text);

insert into fold_base values
(lambda(s, op)(op(s) + (s * 10.0 - 5.0)), 'fold: op(s) + (s*10 - 5)');

insert into residual_fold
select b.fn(2.0, _), b.description
from fold_base b;

select r.description, h.description,
       r.fn(h.fn)                           as staged,
       b.fn(2.0, h.fn)                      as direct,
       r.fn(h.fn) - b.fn(2.0, h.fn)         as diff
from residual_fold r, fold_base b, unary_helpers h
order by h.description;

\echo "------------------------------------------------------------------------------------------------------------------------------"
\echo "Test 12: constant folding in a first-order residual -- held scalar, all-constant tail"

-- f(_, 5.0) bakes b = 5.0, leaving a + (5.0*2.0 + 3.0*4.0); the all-constant tail folds
-- to a + 22.0. A purely scalar residual must still fold and round-trip correctly.
drop table if exists fold_first;
drop table if exists residual_fold_scalar;

create table fold_first(fn lambda(float, float -> float) not null, description text);
create table residual_fold_scalar(fn lambda(float -> float) not null, description text);

insert into fold_first values
(lambda(a, b)(a + (b * 2.0 + 3.0 * 4.0)), 'fold: a + (b*2 + 3*4)');

insert into residual_fold_scalar
select b.fn(_, 5.0), b.description
from fold_first b;

select r.description,
       r.fn(1.0)                            as staged,
       b.fn(1.0, 5.0)                       as direct,
       r.fn(1.0) - b.fn(1.0, 5.0)           as diff
from residual_fold_scalar r, fold_first b
order by r.description;

----------------------------------------------------------------------------------------------------------------------------------------
-- Disable debugging
set custom_lambda_debugging_var TO off;
\set ECHO none
\pset pager on
----------------------------------------------------------------------------------------------------------------------------------------
