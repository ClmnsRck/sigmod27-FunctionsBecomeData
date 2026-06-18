--SPLIT
-- 17 10000 50
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 10000),
    (select * from lambdas_hol where id <= 50),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 20000 50
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 20000),
    (select * from lambdas_hol where id <= 50),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 30000 50
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 30000),
    (select * from lambdas_hol where id <= 50),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 40000 50
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 40000),
    (select * from lambdas_hol where id <= 50),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 50000 50
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 50000),
    (select * from lambdas_hol where id <= 50),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 60000 50
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 60000),
    (select * from lambdas_hol where id <= 50),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 70000 50
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 70000),
    (select * from lambdas_hol where id <= 50),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 80000 50
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 80000),
    (select * from lambdas_hol where id <= 50),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 10000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 10000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 20000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 20000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 30000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 30000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 40000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 40000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 50000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 50000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 60000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 60000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 70000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 70000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 80000 100
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 80000),
    (select * from lambdas_hol where id <= 100),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 10000 150
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 10000),
    (select * from lambdas_hol where id <= 150),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 20000 150
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 20000),
    (select * from lambdas_hol where id <= 150),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 30000 150
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 30000),
    (select * from lambdas_hol where id <= 150),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 40000 150
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 40000),
    (select * from lambdas_hol where id <= 150),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 50000 150
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 50000),
    (select * from lambdas_hol where id <= 150),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 60000 150
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 60000),
    (select * from lambdas_hol where id <= 150),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 70000 150
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 70000),
    (select * from lambdas_hol where id <= 150),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 80000 150
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 80000),
    (select * from lambdas_hol where id <= 150),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 10000 200
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 10000),
    (select * from lambdas_hol where id <= 200),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 20000 200
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 20000),
    (select * from lambdas_hol where id <= 200),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 30000 200
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 30000),
    (select * from lambdas_hol where id <= 200),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 40000 200
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 40000),
    (select * from lambdas_hol where id <= 200),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 50000 200
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 50000),
    (select * from lambdas_hol where id <= 200),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 60000 200
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 60000),
    (select * from lambdas_hol where id <= 200),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 70000 200
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 70000),
    (select * from lambdas_hol where id <= 200),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 80000 200
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 80000),
    (select * from lambdas_hol where id <= 200),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 10000 250
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 10000),
    (select * from lambdas_hol where id <= 250),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 20000 250
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 20000),
    (select * from lambdas_hol where id <= 250),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 30000 250
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 30000),
    (select * from lambdas_hol where id <= 250),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 40000 250
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 40000),
    (select * from lambdas_hol where id <= 250),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 50000 250
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 50000),
    (select * from lambdas_hol where id <= 250),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 60000 250
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 60000),
    (select * from lambdas_hol where id <= 250),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 70000 250
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 70000),
    (select * from lambdas_hol where id <= 250),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 80000 250
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 80000),
    (select * from lambdas_hol where id <= 250),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 10000 300
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 10000),
    (select * from lambdas_hol where id <= 300),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 20000 300
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 20000),
    (select * from lambdas_hol where id <= 300),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 30000 300
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 30000),
    (select * from lambdas_hol where id <= 300),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 40000 300
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 40000),
    (select * from lambdas_hol where id <= 300),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 50000 300
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 50000),
    (select * from lambdas_hol where id <= 300),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 60000 300
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 60000),
    (select * from lambdas_hol where id <= 300),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 70000 300
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 70000),
    (select * from lambdas_hol where id <= 300),
    NTHREADS_MARKER, 0);

--SPLIT
-- 17 80000 300
select * from apply_mt(
    lambda(a:[x:float, y:float, z:float],
            b:[f:(float, float, float->float), g:(float,float,float,(float, float, float->float)->float)])
        ((b.g(a.x, a.y, a.z, b.f) + b.g(a.z, a.y, a.x, b.f)) / 2),
    (select x, y, z from nums where id <= 80000),
    (select * from lambdas_hol where id <= 300),
    NTHREADS_MARKER, 0);
