--SPLIT
-- 17 10000 5
SELECT * FROM kmeans_sql_iter(10000, 5, 20);

--SPLIT
-- 17 10000 10
SELECT * FROM kmeans_sql_iter(10000, 10, 20);

--SPLIT
-- 17 10000 20
SELECT * FROM kmeans_sql_iter(10000, 20, 20);

--SPLIT
-- 17 30000 5
SELECT * FROM kmeans_sql_iter(30000, 5, 20);

--SPLIT
-- 17 30000 10
SELECT * FROM kmeans_sql_iter(30000, 10, 20);

--SPLIT
-- 17 30000 20
SELECT * FROM kmeans_sql_iter(30000, 20, 20);

--SPLIT
-- 17 50000 5
SELECT * FROM kmeans_sql_iter(50000, 5, 20);

--SPLIT
-- 17 50000 10
SELECT * FROM kmeans_sql_iter(50000, 10, 20);

--SPLIT
-- 17 50000 20
SELECT * FROM kmeans_sql_iter(50000, 20, 20);

--SPLIT
-- 17 80000 5
SELECT * FROM kmeans_sql_iter(80000, 5, 20);

--SPLIT
-- 17 80000 10
SELECT * FROM kmeans_sql_iter(80000, 10, 20);

--SPLIT
-- 17 80000 20
SELECT * FROM kmeans_sql_iter(80000, 20, 20);
