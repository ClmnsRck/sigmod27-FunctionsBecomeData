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
set jit='off';                      --enforce no jit (L1 is the working free-from-UDF path)

-- ============================================================================
-- ROBUSTNESS / ADVERSARIAL tester for UDF-free lambda calls -- HIGHER ORDER.
--
-- Purpose: a regression net for the day the planner/executor learns to treat
-- lambda assembly specially (Tier 2/3). The danger of that work is becoming
-- NARROW-MINDED -- assuming every query is "one lambda, only in the SELECT row,
-- evaluated once per data tuple as a nested OUTER loop over a lambda x data
-- cross product". The queries below deliberately violate every clause of that
-- assumption AND use higher-order lambdas (mostly 3rd-order h(.., g, f)), so a
-- bug that only shows up once lambdas are injected into each other is caught.
--
-- Lambda orders in play:
--   f  : 1st order   lambda(x, y -> ..)
--   g  : 2nd order   lambda(a, b, c, (x,y->..) -> ..)            -- injects f
--   h  : 3rd order   lambda(a, (..,(x,y->..)->..), (x,y->..) -> ..) -- injects g and f
--
-- Each query is tagged with:
--   ORDER:    highest lambda order exercised
--   STRESSES: which narrow assumption it breaks
--   EXPECT:   the semantically correct behaviour to preserve
--   STATUS:   how it behaves on the current build (probed 2026-06-09)
--
-- Queries that currently CRASH the backend (signal 11) are left COMMENTED OUT
-- so the script runs to completion; uncomment them as the implementation
-- improves -- they are the most valuable landmines in here.
-- ============================================================================

--drop all tables, to create new ones
drop table if exists nums_smol;
drop table if exists data_keyed;

------------------------------------------create new tables and fill them with usable data----------------------------------------------
create table nums_smol(x float not null, y float not null, z float not null, a float not null, b float not null, c float not null, d float not null);

insert into nums_smol (x, y, z, a, b, c, d)
select random()::float, random()::float, random()::float,
       random()::float, random()::float, random()::float, random()::float
from generate_series(1, 2000);

-- data table that carries a KEY selecting which lambda applies to each row.
-- 'which' references lambdas.id, so the correct semantics is a JOIN, not a
-- cross product. This is the correctness landmine for a cartesian impl.
create table data_keyed(x float not null, y float not null, z float not null, which int not null);
insert into data_keyed
select random()::float, random()::float, random()::float, (4 + (i % 2))
from generate_series(1, 2000) i;
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
-- Higher-Order (2nd) lambdas
create table lambdas_ho (
    id int primary key,
    g lambda(float8, float8, float8, (float8, float8 -> float8) -> float8) not null,
    description text
);
-- Third-Order lambdas
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

-- First-Order Lambdas (float, float -> float)
insert into lambdas values
(4, lambda(x, y)(exp(x/10.0) + exp(y/10.0)), 'First-Order: Exp-Check'),
(5, lambda(x, y)(x + y), 'First-Order: Sanity Check(x + y)');

-- Second Order Lambdas (f, f, f, (f, f -> f) -> f)
insert into lambdas_ho values
(4, lambda(a, b, divisor, op)(op(a, b) * divisor), 'HO: multiplication'),
(5, lambda(a, b, c, op)(c + op(a, b)), 'HO: Sanity check(+)');

-- Third Order Lambdas (f, (f,f,f,(f,f->f)->f), (f,f->f) -> f)
insert into lambdas_hoho values
(1, lambda(a, op_ho, op)(a + op(a, a) * op_ho(a, a, a, op)), 'HOHO: multiplication');

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- ############################################################################
-- ## Queries that currently RUN -- keep them passing (and correct!)         ##
-- ############################################################################

\echo "=== Q1: 3rd-order lambda ONLY in WHERE, never selected ==="
-- ORDER:    3rd (h injects g and f)
-- STRESSES: the assumption that lambda evaluation can be attached to the
--           SELECT projection. Here the lambda exists solely as a filter.
-- EXPECT:   filtering happens; output columns contain no lambda result.
-- STATUS:   OK
select ns.x, ns.y
from lambdas l, lambdas_ho lho, lambdas_hoho hoho, nums_smol ns
where hoho.h(ns.x, lho.g, l.f) >= 1
limit 3;

\echo "------------------------------------------------------------------------------------------------------------------------------"

\echo "=== Q2: SAME 3rd-order lambda in WHERE and in SELECT ==="
-- ORDER:    3rd
-- STRESSES: the assumption that a lambda appears once. The identical 3rd-order
--           call is a filter AND a projected value; both must agree.
-- EXPECT:   every returned row satisfies r = h(x, g, f) >= 1.
-- STATUS:   OK
select ns.x, hoho.h(ns.x, lho.g, l.f) as r
from lambdas l, lambdas_ho lho, lambdas_hoho hoho, nums_smol ns
where hoho.h(ns.x, lho.g, l.f) >= 1
limit 3;

\echo "------------------------------------------------------------------------------------------------------------------------------"

\echo "=== Q3: same 3rd-order call THREE times (CSE) ==="
-- ORDER:    3rd
-- STRESSES: an impl that builds/injects a separate lambda per textual
--           occurrence -- here the same h-injection appears 3x.
-- EXPECT:   a, b, and the filter are all consistent (b = 2*a, a > 0).
-- STATUS:   OK
select hoho.h(ns.x, lho.g, l.f) as a, hoho.h(ns.x, lho.g, l.f) * 2 as b
from lambdas l, lambdas_ho lho, lambdas_hoho hoho, nums_smol ns
where hoho.h(ns.x, lho.g, l.f) > 0
limit 3;

\echo "------------------------------------------------------------------------------------------------------------------------------"

\echo "=== Q4: MIXED orders -- 2nd order in SELECT, 3rd order in WHERE ==="
-- ORDER:    2nd + 3rd in one query
-- STRESSES: the single-lambda assumption AND the single-order assumption: g
--           (2nd) is projected, h (3rd) filters, and both inject the same f.
-- EXPECT:   r = g(x,y,z,f) on rows where h(x,g,f) >= 1.
-- STATUS:   OK
select ns.x, lho.g(ns.x, ns.y, ns.z, l.f) as r
from lambdas l, lambdas_ho lho, lambdas_hoho hoho, nums_smol ns
where hoho.h(ns.x, lho.g, l.f) >= 1
limit 3;

\echo "------------------------------------------------------------------------------------------------------------------------------"

\echo "=== Q5: 3rd-order lambda result in GROUP BY ==="
-- ORDER:    3rd
-- STRESSES: lambda output feeding a grouping key -- a pipeline breaker the
--           lambda-outer/data-inner shape does not naturally provide.
-- EXPECT:   one row per distinct rounded lambda value, with its count.
-- STATUS:   OK
select round(hoho.h(ns.x, lho.g, l.f)::numeric, 1) as bucket, count(*)
from lambdas l, lambdas_ho lho, lambdas_hoho hoho, nums_smol ns
group by round(hoho.h(ns.x, lho.g, l.f)::numeric, 1)
order by bucket
limit 5;

\echo "------------------------------------------------------------------------------------------------------------------------------"

\echo "=== Q6: 3rd-order lambda inside an aggregate + HAVING ==="
-- ORDER:    3rd
-- STRESSES: lambda result consumed by an aggregate, then re-used in HAVING.
--           Grouping is above the per-row lambda eval, not below it.
-- EXPECT:   only HOHO groups whose summed result exceeds the threshold.
-- STATUS:   OK
select hoho.description, sum(hoho.h(ns.x, lho.g, l.f)) as total
from lambdas l, lambdas_ho lho, lambdas_hoho hoho, nums_smol ns
group by hoho.description
having sum(hoho.h(ns.x, lho.g, l.f)) > 100
order by total;

\echo "------------------------------------------------------------------------------------------------------------------------------"

\echo "=== Q7: 3rd-order lambda result in ORDER BY ... LIMIT (top-N) ==="
-- ORDER:    3rd
-- STRESSES: a Sort over the lambda result across ALL combinations x data; an
--           impl that emits per-combination blocks must still globally order.
-- EXPECT:   the 5 largest h(x,g,f) values overall.
-- STATUS:   OK
select ns.x, ns.y, hoho.h(ns.x, lho.g, l.f) as r
from lambdas l, lambdas_ho lho, lambdas_hoho hoho, nums_smol ns
order by hoho.h(ns.x, lho.g, l.f) desc
limit 5;

\echo "------------------------------------------------------------------------------------------------------------------------------"

\echo "=== Q8: pure scalar 3rd-order call, NO data relation ==="
-- ORDER:    3rd
-- STRESSES: the assumption that a data relation exists to nest inside. Here
--           there is no inner loop at all -- only the lambda tables, with a
--           constant first argument to h.
-- EXPECT:   one row per (f,g,h) combination, h evaluated on a constant.
-- STATUS:   OK
select hoho.h(1.0, lho.g, l.f) as r, hoho.description
from lambdas l, lambdas_ho lho, lambdas_hoho hoho;

\echo "------------------------------------------------------------------------------------------------------------------------------"

\echo "=== Q9: CORRELATED lambda choice via join key, wrapped in 3rd order ==="
-- ORDER:    3rd (correlated f selected per data row, injected through g into h)
-- STRESSES: the cartesian "every lambda x every data row" assumption. The data
--           row's 'which' column selects WHICH f applies (a join), and that f
--           is then injected into the 3rd-order h.
-- EXPECT:   the chosen f drives each data row -- NOT a blind f cross product.
--           NB: the 1st-order direct-correlated form (l.f(dk.x,dk.y) with the
--           same join) CRASHES; the 3rd-order wrapping currently survives, so
--           this also guards that the two paths stay consistent.
-- STATUS:   OK (verify row semantics if correlation handling changes)
select dk.x, hoho.h(dk.x, lho.g, l.f) as r
from data_keyed dk
join lambdas l on l.id = dk.which,
     lambdas_ho lho, lambdas_hoho hoho
limit 5;

\echo "------------------------------------------------------------------------------------------------------------------------------"

-- ############################################################################
-- ## KNOWN CRASHES (signal 11) as of 2026-06-09 -- the real landmines.      ##
-- ## They crash at BOTH 1st and 3rd order, so these are order-independent   ##
-- ## gaps, not just higher-order regressions. Uncomment to reproduce/fix.   ##
-- ############################################################################

\echo "=== Q10 (COMMENTED, CRASHES): 3rd-order lambda applied to AGGREGATES ==="
-- ORDER:    3rd
-- STRESSES: "lambda runs once per data tuple". Here the lambda's data argument
--           is an aggregate, so h must run ONCE PER GROUP, after aggregation.
-- EXPECT:   one row per (f,g,h) combination, h(avg(x), g, f).
-- STATUS:   CRASH (signal 11) -- also crashes at 1st order
-- select hoho.id, hoho.h(avg(ns.x), lho.g, l.f) as r
-- from lambdas l, lambdas_ho lho, lambdas_hoho hoho, nums_smol ns
-- group by hoho.id, hoho.h, lho.g, l.f;

\echo "------------------------------------------------------------------------------------------------------------------------------"

\echo "=== Q11 (COMMENTED, CRASHES): 2nd-order lambda in a JOIN ... ON between two data rels ==="
-- ORDER:    2nd (g needs two data-side floats, so it gates a data x data join)
-- STRESSES: lambda living in a join qualifier (not WHERE/SELECT) between two
--           DATA relations -- the lambda is neither the outer driver nor a
--           projection; it gates the join itself.
-- EXPECT:   pairs (a,b) where g(a.x, b.x, a.y, f) > 1.
-- STATUS:   CRASH (signal 11) -- also crashes at 1st order
-- select a.x as ax, b.x as bx
-- from lambdas l, lambdas_ho lho,
--      nums_smol a join nums_smol b on lho.g(a.x, b.x, a.y, l.f) > 1
-- limit 3;

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
