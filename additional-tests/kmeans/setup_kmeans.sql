--meta flags, jit needs to be on, 'load llvm' loads dependencies
set jit='on';
load 'llvmjit.so';

select setseed(0.42);

--------------------------------------------------------- load functions -----------------------------------------------------------
-- Returns: point columns + "cluster" (int4)
create or replace function kmeans_v2(lambdatable, lambdatable, "lambda", int, int)
returns setof record
as '$libdir/kmeans_v2_ext.so', 'kmeans_v2'
language C STRICT;
----------------------------------------------------------------------------------------------------------------------------------------

-------------------------------------------------Setup K-Means benchmark---------------------------------------------------
-- 20 cluster centres arranged in a 4×5 grid over [1,9]×[1,9].
-- Points are distributed evenly (5000 per cluster) with ±0.7 Gaussian-style
-- uniform noise, giving well-separated but non-trivial clusters.
drop table if exists kmeans_centroids;
drop table if exists kmeans_points;

create UNLOGGED table kmeans_centroids(
    cid int not null,
    cx  float8 not null,
    cy  float8 not null,
    primary key (cid)
);

-- initial centroids: true grid positions + small random perturbation so the
-- algorithm must do real work to converge
insert into kmeans_centroids (cid, cx, cy)
select
    ((row_num - 1) * 5 + col_num) as cid,
    (2 * row_num - 1 + (random() * 0.4 - 0.2))::float8 as cx,
    (2 * col_num - 1 + (random() * 0.4 - 0.2))::float8 as cy
from generate_series(1, 4) row_num, generate_series(1, 5) col_num;

create UNLOGGED table kmeans_points(
    id bigint not null,
    x  float8 not null,
    y  float8 not null,
    primary key (id)
);

insert into kmeans_points (id, x, y)
select
    gs as id,
    (2 * c.row_num - 1 + (random() * 1.4 - 0.7))::float8 as x,
    (2 * c.col_num - 1 + (random() * 1.4 - 0.7))::float8 as y
from generate_series(1, 100000) gs
join (
    select ((row_num - 1) * 5 + col_num) as cid, row_num, col_num
    from generate_series(1, 4) row_num, generate_series(1, 5) col_num
) c on c.cid = ((gs - 1) % 20) + 1;

-- Pure-SQL iterative k-means reference implementation (plpgsql).
-- Used as the baseline for comparison with kmeans_v2 UDF.
create or replace function kmeans_sql_iter(ndata int, k int, maxit int)
returns table(x float8, y float8, cluster int) as $$
-- prefer columns over the RETURNS TABLE out-vars (x, y, cluster) so unqualified
-- "cluster" in the centroid update resolves to the _km_pts column, not the var
#variable_conflict use_column
declare
    iter int;
begin
    drop table if exists _km_pts;
    drop table if exists _km_cents;

    create temp table _km_pts as
        select p.id, p.x, p.y, ((p.id::int - 1) % k) + 1 as cluster
        from kmeans_points p
        where p.id <= ndata;

    create temp table _km_cents as
        select cid, cx, cy from kmeans_centroids where cid <= k;

    for iter in 1..maxit loop
        -- Assignment: each point → nearest centroid (CROSS JOIN LATERAL, JIT-able)
        with nearest as (
            select pt.id, c.cid as new_cluster
            from _km_pts pt
            cross join lateral (
                select ce.cid
                from _km_cents ce
                order by (pt.x - ce.cx)^2 + (pt.y - ce.cy)^2
                limit 1
            ) c
        )
        update _km_pts pt set cluster = n.new_cluster
        from nearest n where pt.id = n.id;

        -- Update: recompute centroid positions
        update _km_cents ce set cx = sub.mx, cy = sub.my
        from (
            select cluster, avg(x) as mx, avg(y) as my
            from _km_pts group by cluster
        ) sub
        where ce.cid = sub.cluster;
    end loop;

    return query select pt.x, pt.y, pt.cluster from _km_pts pt;

    drop table _km_pts;
    drop table _km_cents;
end;
$$ language plpgsql;

ANALYZE;
