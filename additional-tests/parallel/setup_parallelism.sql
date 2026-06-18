--meta flags, jit needs to be on, 'load llvm' loads dependencies
set jit='on';
load 'llvmjit.so';

select setseed(0.42);

--------------------------------------------------------- load all functions -----------------------------------------------------------
-- Returns: Datatable(tables[0]), Lambdatable(tables[1]), "applied_lambda", "result"
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

-------------------------------------------------Setup lambda scaling---------------------------------------------------
drop table if exists lambdas_hol;
drop table if exists lambdas_fol;
drop table if exists lambdas_hol_base;
drop table if exists lambdas_fol_base;

-- Column-stored lambdas: signature on the column. A scalar lambda literal only
-- gets its signature from a direct INSERT ... VALUES, so seed each into a 1-row
-- template table and replicate to 500 rows by COLUMN copy.
create UNLOGGED table lambdas_hol_base(
    k int not null primary key,
    f lambda(float8, float8, float8 -> float8) not null,
    g lambda(float8, float8, float8, (float8, float8, float8 -> float8) -> float8) not null
);

insert into lambdas_hol_base (k, f, g) values
    (0, lambda(x, y, z)(x + y * z), lambda(x, y, z, f)(abs(f(x, y, z)) * 0.9 + f(x, y, z)));

create UNLOGGED table lambdas_hol(
    f lambda(float8, float8, float8 -> float8) not null,
    g lambda(float8, float8, float8, (float8, float8, float8 -> float8) -> float8) not null,
    id bigint not null,
    primary key (id)
);

-- First-order baseline: the fully-inlined per-row computation as a scalar
-- (x, y, z) -> float lambda (the old row-context form had unused f/g inputs).
create UNLOGGED table lambdas_fol_base(
    k int not null primary key,
    f lambda(float8, float8, float8 -> float8) not null
);

insert into lambdas_fol_base (k, f) values
    (0, lambda(x, y, z)(((abs(x + y * z) * 0.9 + (x + y * z)) + (abs(z + y * x) * 0.9 + (z + y * x))) / 2));

create UNLOGGED table lambdas_fol(
    f lambda(float8, float8, float8 -> float8) not null,
    id bigint not null,
    primary key (id)
);

insert into lambdas_hol (id, f, g)
select tup_num as id, base.f, base.g
from generate_series(1, 500) as tup_num
join lambdas_hol_base as base on base.k = 0;

insert into lambdas_fol (id, f)
select tup_num as id, base.f
from generate_series(1, 500) as tup_num
join lambdas_fol_base as base on base.k = 0;

ANALYZE;