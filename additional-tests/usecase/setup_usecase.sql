--meta flags, jit needs to be on, 'load llvm' loads dependencies
set jit='on';
load 'llvmjit.so';

select setseed(0.42);

--------------------------------------------------------- load functions -----------------------------------------------------------
-- Map operator. Returns: data columns + "result"
create or replace function apply_mt("lambda", lambdatable, lambdatable, int, int)
returns setof record
as '$libdir/apply_mt_ext.so', 'apply_mt'
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
from generate_series(1, 100000) as tup_num;

-------------------------------------------------Setup model (lambda) table---------------------------------------------------
-- Each row is a candidate "model": a first-order lambda f and the wrapper g.
-- 10 structurally distinct FOL variants cycle across the rows. The HOL Map
-- operator scores every model over the data; the use case is model selection.
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
