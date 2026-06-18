--SPLIT
-- 17 1000 50
SELECT avg(result) FROM apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 1000),
    (select * from lambdas_hol where id <= 50),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 5000 50
SELECT avg(result) FROM apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 5000),
    (select * from lambdas_hol where id <= 50),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 10000 50
SELECT avg(result) FROM apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 10000),
    (select * from lambdas_hol where id <= 50),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 30000 50
SELECT avg(result) FROM apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 30000),
    (select * from lambdas_hol where id <= 50),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 50000 50
SELECT avg(result) FROM apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 50000),
    (select * from lambdas_hol where id <= 50),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 80000 50
SELECT avg(result) FROM apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 80000),
    (select * from lambdas_hol where id <= 50),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 10000 2
SELECT avg(result) FROM apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 10000),
    (select * from lambdas_hol where id <= 2),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 10000 5
SELECT avg(result) FROM apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 10000),
    (select * from lambdas_hol where id <= 5),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 10000 10
SELECT avg(result) FROM apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 10000),
    (select * from lambdas_hol where id <= 10),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 10000 20
SELECT avg(result) FROM apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 10000),
    (select * from lambdas_hol where id <= 20),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 10000 100
SELECT avg(result) FROM apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 10000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);
