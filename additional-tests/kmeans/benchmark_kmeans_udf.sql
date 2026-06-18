--SPLIT
-- 17 10000 5
SELECT * FROM kmeans_v2(
    (SELECT x, y FROM kmeans_points  WHERE id  <= 10000),
    (SELECT cx, cy FROM kmeans_centroids WHERE cid <= 5),
    lambda(p:[x:float8, y:float8], c:[cx:float8, cy:float8])((p.x - c.cx)^2 + (p.y - c.cy)^2),
    NTHREADS_MARKER, 20);

--SPLIT
-- 17 10000 10
SELECT * FROM kmeans_v2(
    (SELECT x, y FROM kmeans_points  WHERE id  <= 10000),
    (SELECT cx, cy FROM kmeans_centroids WHERE cid <= 10),
    lambda(p:[x:float8, y:float8], c:[cx:float8, cy:float8])((p.x - c.cx)^2 + (p.y - c.cy)^2),
    NTHREADS_MARKER, 20);

--SPLIT
-- 17 10000 20
SELECT * FROM kmeans_v2(
    (SELECT x, y FROM kmeans_points  WHERE id  <= 10000),
    (SELECT cx, cy FROM kmeans_centroids WHERE cid <= 20),
    lambda(p:[x:float8, y:float8], c:[cx:float8, cy:float8])((p.x - c.cx)^2 + (p.y - c.cy)^2),
    NTHREADS_MARKER, 20);

--SPLIT
-- 17 30000 5
SELECT * FROM kmeans_v2(
    (SELECT x, y FROM kmeans_points  WHERE id  <= 30000),
    (SELECT cx, cy FROM kmeans_centroids WHERE cid <= 5),
    lambda(p:[x:float8, y:float8], c:[cx:float8, cy:float8])((p.x - c.cx)^2 + (p.y - c.cy)^2),
    NTHREADS_MARKER, 20);

--SPLIT
-- 17 30000 10
SELECT * FROM kmeans_v2(
    (SELECT x, y FROM kmeans_points  WHERE id  <= 30000),
    (SELECT cx, cy FROM kmeans_centroids WHERE cid <= 10),
    lambda(p:[x:float8, y:float8], c:[cx:float8, cy:float8])((p.x - c.cx)^2 + (p.y - c.cy)^2),
    NTHREADS_MARKER, 20);

--SPLIT
-- 17 30000 20
SELECT * FROM kmeans_v2(
    (SELECT x, y FROM kmeans_points  WHERE id  <= 30000),
    (SELECT cx, cy FROM kmeans_centroids WHERE cid <= 20),
    lambda(p:[x:float8, y:float8], c:[cx:float8, cy:float8])((p.x - c.cx)^2 + (p.y - c.cy)^2),
    NTHREADS_MARKER, 20);

--SPLIT
-- 17 50000 5
SELECT * FROM kmeans_v2(
    (SELECT x, y FROM kmeans_points  WHERE id  <= 50000),
    (SELECT cx, cy FROM kmeans_centroids WHERE cid <= 5),
    lambda(p:[x:float8, y:float8], c:[cx:float8, cy:float8])((p.x - c.cx)^2 + (p.y - c.cy)^2),
    NTHREADS_MARKER, 20);

--SPLIT
-- 17 50000 10
SELECT * FROM kmeans_v2(
    (SELECT x, y FROM kmeans_points  WHERE id  <= 50000),
    (SELECT cx, cy FROM kmeans_centroids WHERE cid <= 10),
    lambda(p:[x:float8, y:float8], c:[cx:float8, cy:float8])((p.x - c.cx)^2 + (p.y - c.cy)^2),
    NTHREADS_MARKER, 20);

--SPLIT
-- 17 50000 20
SELECT * FROM kmeans_v2(
    (SELECT x, y FROM kmeans_points  WHERE id  <= 50000),
    (SELECT cx, cy FROM kmeans_centroids WHERE cid <= 20),
    lambda(p:[x:float8, y:float8], c:[cx:float8, cy:float8])((p.x - c.cx)^2 + (p.y - c.cy)^2),
    NTHREADS_MARKER, 20);

--SPLIT
-- 17 80000 5
SELECT * FROM kmeans_v2(
    (SELECT x, y FROM kmeans_points  WHERE id  <= 80000),
    (SELECT cx, cy FROM kmeans_centroids WHERE cid <= 5),
    lambda(p:[x:float8, y:float8], c:[cx:float8, cy:float8])((p.x - c.cx)^2 + (p.y - c.cy)^2),
    NTHREADS_MARKER, 20);

--SPLIT
-- 17 80000 10
SELECT * FROM kmeans_v2(
    (SELECT x, y FROM kmeans_points  WHERE id  <= 80000),
    (SELECT cx, cy FROM kmeans_centroids WHERE cid <= 10),
    lambda(p:[x:float8, y:float8], c:[cx:float8, cy:float8])((p.x - c.cx)^2 + (p.y - c.cy)^2),
    NTHREADS_MARKER, 20);

--SPLIT
-- 17 80000 20
SELECT * FROM kmeans_v2(
    (SELECT x, y FROM kmeans_points  WHERE id  <= 80000),
    (SELECT cx, cy FROM kmeans_centroids WHERE cid <= 20),
    lambda(p:[x:float8, y:float8], c:[cx:float8, cy:float8])((p.x - c.cx)^2 + (p.y - c.cy)^2),
    NTHREADS_MARKER, 20);
