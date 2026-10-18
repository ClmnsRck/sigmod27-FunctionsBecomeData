--meta flags, jit needs to be on, 'load llvm' loads dependencies
set jit='on';
load 'llvmjit.so';

select setseed(0.42);

--------------------------------------------------------- load all functions -----------------------------------------------------------
-- The map operator on postgres parallel workers. Returns the data columns plus
-- "result" for every (data row, lambda) pair. arg 4 is the worker count, arg 5 the
-- evaluator: 0 = checked (interpreter with jit off, standard expression JIT with
-- jit on), 1 = L3, the fast JIT path the benchmarks use, 2 = L3 + row tuple.
create or replace function apply_mt_pw("lambda", lambdatable, lambdatable, int, int)
returns setof record
as '$libdir/apply_mt_pw_ext.so', 'apply_mt_pw'
language C STRICT;

-- aggregating sibling: each job keeps a local sum, so no N x M result crosses shared
-- memory. Returns the flat average over all N x M results as one row.
create or replace function apply_mt_agg_pw("lambda", lambdatable, lambdatable, int, int)
returns setof record
as '$libdir/apply_mt_pw_ext.so', 'apply_mt_agg_pw'
language C STRICT;
----------------------------------------------------------------------------------------------------------------------------------------

------------------------------------------create new tables and fill them with usable data----------------------------------------------
drop table if exists nums;

create UNLOGGED table nums(id bigint not null, x float not null, y float not null, z float not null, primary key (id));

insert into nums
select tup_num as id,
    (random() + 0.5) as x,
    (random() + 0.5) as y,
    (random() + 0.5) as z
-- Must be >= max(SCALING_DATA) in generate_benchmarks.py: the blobs select
-- `where id <= N`, so a table that is too small silently returns fewer rows
-- instead of failing.
from generate_series(1, 120000) as tup_num;

-------------------------------------------------Setup lambda scaling---------------------------------------------------
-- 10 structurally distinct FOL variants cycle across the 500 rows so that
-- the PostgreSQL JIT cannot batch-compile a single common expression.
-- Variant (id-1)%10:
--   0: x + y*z    1: x*y + z    2: x - y + z   3: x*z + y   4: (x+y)*z
--   5: x*x + y*z  6: x*y*z      7: (x-z)*(y+1) 8: x + y + z 9: x*(y-z)
drop table if exists lambdas_hol;
drop table if exists lambdas_hol_base;

-- Column-stored lambdas: signature on the column. A scalar lambda literal only
-- gets its signature from a direct INSERT ... VALUES (not INSERT ... SELECT), so
-- seed the 10 f variants into a template table (keyed 0..9) and replicate to
-- 500 rows by COLUMN copy, cycling (id-1) % 10.
create UNLOGGED table lambdas_hol_base(
    k int not null primary key,
    f lambda(float8, float8, float8 -> float8) not null,
    g lambda(float8, float8, float8, (float8, float8, float8 -> float8) -> float8) not null
);

insert into lambdas_hol_base (k, f, g) values
    (0, lambda(x, y, z)(x + y * z),          lambda(x, y, z, f)(abs(f(x, y, z)) * 0.9 + f(x, y, z))),
    (1, lambda(x, y, z)(x * y + z),          lambda(x, y, z, f)(abs(f(x, y, z)) * 0.9 + f(x, y, z))),
    (2, lambda(x, y, z)(x - y + z),          lambda(x, y, z, f)(abs(f(x, y, z)) * 0.9 + f(x, y, z))),
    (3, lambda(x, y, z)(x * z + y),          lambda(x, y, z, f)(abs(f(x, y, z)) * 0.9 + f(x, y, z))),
    (4, lambda(x, y, z)((x + y) * z),        lambda(x, y, z, f)(abs(f(x, y, z)) * 0.9 + f(x, y, z))),
    (5, lambda(x, y, z)(x * x + y * z),      lambda(x, y, z, f)(abs(f(x, y, z)) * 0.9 + f(x, y, z))),
    (6, lambda(x, y, z)(x * y * z),          lambda(x, y, z, f)(abs(f(x, y, z)) * 0.9 + f(x, y, z))),
    (7, lambda(x, y, z)((x - z) * (y + 1.0)), lambda(x, y, z, f)(abs(f(x, y, z)) * 0.9 + f(x, y, z))),
    (8, lambda(x, y, z)(x + y + z),          lambda(x, y, z, f)(abs(f(x, y, z)) * 0.9 + f(x, y, z))),
    (9, lambda(x, y, z)(x * (y - z)),        lambda(x, y, z, f)(abs(f(x, y, z)) * 0.9 + f(x, y, z)));

create UNLOGGED table lambdas_hol(
    f lambda(float8, float8, float8 -> float8) not null,
    g lambda(float8, float8, float8, (float8, float8, float8 -> float8) -> float8) not null,
    id bigint not null,
    primary key (id)
);

insert into lambdas_hol (id, f, g)
select tup_num as id, base.f, base.g
from generate_series(1, 500) as tup_num
join lambdas_hol_base as base on base.k = (tup_num - 1) % 10;

ANALYZE;
