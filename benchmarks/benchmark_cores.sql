--SPLIT
-- 0 80000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 80000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);

--SPLIT
-- 1 80000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 80000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);

--SPLIT
-- 2 80000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 80000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);

--SPLIT
-- 4 80000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 80000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);

--SPLIT
-- 8 80000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 80000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);

--SPLIT
-- 16 80000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 80000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);

--SPLIT
-- 32 80000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 80000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);
