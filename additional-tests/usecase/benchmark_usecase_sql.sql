--SPLIT
-- 17 1000 50
WITH data_scan AS NOT MATERIALIZED (
  SELECT
    d.id AS data_id,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e01,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e02,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e03,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e04,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e05,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e06,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e07,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e08,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e09,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e10,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e11,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e12,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e13,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e14,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e15,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e16,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e17,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e18,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e19,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e20,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e21,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e22,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e23,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e24,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e25,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e26,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e27,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e28,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e29,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e30,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e31,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e32,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e33,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e34,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e35,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e36,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e37,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e38,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e39,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e40,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e41,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e42,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e43,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e44,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e45,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e46,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e47,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e48,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e49,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e50
  FROM nums d
  WHERE d.id <= 1000
)
SELECT avg(v.result)
FROM data_scan s
CROSS JOIN LATERAL (VALUES (01, s.e01),(02, s.e02),(03, s.e03),(04, s.e04),(05, s.e05),
    (06, s.e06),(07, s.e07),(08, s.e08),(09, s.e09),(10, s.e10),
    (11, s.e11),(12, s.e12),(13, s.e13),(14, s.e14),(15, s.e15),
    (16, s.e16),(17, s.e17),(18, s.e18),(19, s.e19),(20, s.e20),
    (21, s.e21),(22, s.e22),(23, s.e23),(24, s.e24),(25, s.e25),
    (26, s.e26),(27, s.e27),(28, s.e28),(29, s.e29),(30, s.e30),
    (31, s.e31),(32, s.e32),(33, s.e33),(34, s.e34),(35, s.e35),
    (36, s.e36),(37, s.e37),(38, s.e38),(39, s.e39),(40, s.e40),
    (41, s.e41),(42, s.e42),(43, s.e43),(44, s.e44),(45, s.e45),
    (46, s.e46),(47, s.e47),(48, s.e48),(49, s.e49),(50, s.e50)
) AS v(lambda_id, result);

--SPLIT
-- 17 5000 50
WITH data_scan AS NOT MATERIALIZED (
  SELECT
    d.id AS data_id,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e01,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e02,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e03,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e04,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e05,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e06,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e07,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e08,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e09,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e10,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e11,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e12,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e13,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e14,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e15,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e16,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e17,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e18,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e19,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e20,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e21,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e22,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e23,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e24,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e25,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e26,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e27,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e28,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e29,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e30,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e31,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e32,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e33,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e34,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e35,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e36,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e37,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e38,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e39,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e40,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e41,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e42,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e43,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e44,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e45,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e46,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e47,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e48,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e49,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e50
  FROM nums d
  WHERE d.id <= 5000
)
SELECT avg(v.result)
FROM data_scan s
CROSS JOIN LATERAL (VALUES (01, s.e01),(02, s.e02),(03, s.e03),(04, s.e04),(05, s.e05),
    (06, s.e06),(07, s.e07),(08, s.e08),(09, s.e09),(10, s.e10),
    (11, s.e11),(12, s.e12),(13, s.e13),(14, s.e14),(15, s.e15),
    (16, s.e16),(17, s.e17),(18, s.e18),(19, s.e19),(20, s.e20),
    (21, s.e21),(22, s.e22),(23, s.e23),(24, s.e24),(25, s.e25),
    (26, s.e26),(27, s.e27),(28, s.e28),(29, s.e29),(30, s.e30),
    (31, s.e31),(32, s.e32),(33, s.e33),(34, s.e34),(35, s.e35),
    (36, s.e36),(37, s.e37),(38, s.e38),(39, s.e39),(40, s.e40),
    (41, s.e41),(42, s.e42),(43, s.e43),(44, s.e44),(45, s.e45),
    (46, s.e46),(47, s.e47),(48, s.e48),(49, s.e49),(50, s.e50)
) AS v(lambda_id, result);

--SPLIT
-- 17 10000 50
WITH data_scan AS NOT MATERIALIZED (
  SELECT
    d.id AS data_id,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e01,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e02,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e03,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e04,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e05,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e06,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e07,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e08,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e09,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e10,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e11,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e12,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e13,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e14,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e15,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e16,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e17,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e18,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e19,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e20,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e21,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e22,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e23,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e24,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e25,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e26,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e27,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e28,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e29,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e30,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e31,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e32,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e33,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e34,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e35,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e36,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e37,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e38,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e39,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e40,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e41,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e42,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e43,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e44,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e45,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e46,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e47,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e48,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e49,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e50
  FROM nums d
  WHERE d.id <= 10000
)
SELECT avg(v.result)
FROM data_scan s
CROSS JOIN LATERAL (VALUES (01, s.e01),(02, s.e02),(03, s.e03),(04, s.e04),(05, s.e05),
    (06, s.e06),(07, s.e07),(08, s.e08),(09, s.e09),(10, s.e10),
    (11, s.e11),(12, s.e12),(13, s.e13),(14, s.e14),(15, s.e15),
    (16, s.e16),(17, s.e17),(18, s.e18),(19, s.e19),(20, s.e20),
    (21, s.e21),(22, s.e22),(23, s.e23),(24, s.e24),(25, s.e25),
    (26, s.e26),(27, s.e27),(28, s.e28),(29, s.e29),(30, s.e30),
    (31, s.e31),(32, s.e32),(33, s.e33),(34, s.e34),(35, s.e35),
    (36, s.e36),(37, s.e37),(38, s.e38),(39, s.e39),(40, s.e40),
    (41, s.e41),(42, s.e42),(43, s.e43),(44, s.e44),(45, s.e45),
    (46, s.e46),(47, s.e47),(48, s.e48),(49, s.e49),(50, s.e50)
) AS v(lambda_id, result);

--SPLIT
-- 17 30000 50
WITH data_scan AS NOT MATERIALIZED (
  SELECT
    d.id AS data_id,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e01,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e02,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e03,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e04,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e05,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e06,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e07,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e08,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e09,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e10,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e11,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e12,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e13,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e14,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e15,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e16,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e17,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e18,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e19,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e20,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e21,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e22,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e23,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e24,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e25,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e26,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e27,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e28,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e29,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e30,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e31,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e32,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e33,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e34,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e35,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e36,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e37,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e38,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e39,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e40,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e41,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e42,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e43,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e44,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e45,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e46,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e47,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e48,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e49,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e50
  FROM nums d
  WHERE d.id <= 30000
)
SELECT avg(v.result)
FROM data_scan s
CROSS JOIN LATERAL (VALUES (01, s.e01),(02, s.e02),(03, s.e03),(04, s.e04),(05, s.e05),
    (06, s.e06),(07, s.e07),(08, s.e08),(09, s.e09),(10, s.e10),
    (11, s.e11),(12, s.e12),(13, s.e13),(14, s.e14),(15, s.e15),
    (16, s.e16),(17, s.e17),(18, s.e18),(19, s.e19),(20, s.e20),
    (21, s.e21),(22, s.e22),(23, s.e23),(24, s.e24),(25, s.e25),
    (26, s.e26),(27, s.e27),(28, s.e28),(29, s.e29),(30, s.e30),
    (31, s.e31),(32, s.e32),(33, s.e33),(34, s.e34),(35, s.e35),
    (36, s.e36),(37, s.e37),(38, s.e38),(39, s.e39),(40, s.e40),
    (41, s.e41),(42, s.e42),(43, s.e43),(44, s.e44),(45, s.e45),
    (46, s.e46),(47, s.e47),(48, s.e48),(49, s.e49),(50, s.e50)
) AS v(lambda_id, result);

--SPLIT
-- 17 50000 50
WITH data_scan AS NOT MATERIALIZED (
  SELECT
    d.id AS data_id,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e01,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e02,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e03,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e04,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e05,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e06,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e07,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e08,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e09,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e10,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e11,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e12,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e13,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e14,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e15,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e16,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e17,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e18,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e19,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e20,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e21,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e22,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e23,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e24,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e25,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e26,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e27,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e28,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e29,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e30,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e31,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e32,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e33,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e34,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e35,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e36,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e37,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e38,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e39,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e40,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e41,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e42,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e43,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e44,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e45,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e46,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e47,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e48,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e49,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e50
  FROM nums d
  WHERE d.id <= 50000
)
SELECT avg(v.result)
FROM data_scan s
CROSS JOIN LATERAL (VALUES (01, s.e01),(02, s.e02),(03, s.e03),(04, s.e04),(05, s.e05),
    (06, s.e06),(07, s.e07),(08, s.e08),(09, s.e09),(10, s.e10),
    (11, s.e11),(12, s.e12),(13, s.e13),(14, s.e14),(15, s.e15),
    (16, s.e16),(17, s.e17),(18, s.e18),(19, s.e19),(20, s.e20),
    (21, s.e21),(22, s.e22),(23, s.e23),(24, s.e24),(25, s.e25),
    (26, s.e26),(27, s.e27),(28, s.e28),(29, s.e29),(30, s.e30),
    (31, s.e31),(32, s.e32),(33, s.e33),(34, s.e34),(35, s.e35),
    (36, s.e36),(37, s.e37),(38, s.e38),(39, s.e39),(40, s.e40),
    (41, s.e41),(42, s.e42),(43, s.e43),(44, s.e44),(45, s.e45),
    (46, s.e46),(47, s.e47),(48, s.e48),(49, s.e49),(50, s.e50)
) AS v(lambda_id, result);

--SPLIT
-- 17 80000 50
WITH data_scan AS NOT MATERIALIZED (
  SELECT
    d.id AS data_id,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e01,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e02,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e03,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e04,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e05,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e06,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e07,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e08,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e09,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e10,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e11,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e12,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e13,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e14,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e15,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e16,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e17,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e18,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e19,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e20,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e21,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e22,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e23,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e24,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e25,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e26,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e27,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e28,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e29,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e30,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e31,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e32,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e33,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e34,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e35,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e36,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e37,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e38,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e39,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e40,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e41,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e42,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e43,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e44,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e45,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e46,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e47,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e48,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e49,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e50
  FROM nums d
  WHERE d.id <= 80000
)
SELECT avg(v.result)
FROM data_scan s
CROSS JOIN LATERAL (VALUES (01, s.e01),(02, s.e02),(03, s.e03),(04, s.e04),(05, s.e05),
    (06, s.e06),(07, s.e07),(08, s.e08),(09, s.e09),(10, s.e10),
    (11, s.e11),(12, s.e12),(13, s.e13),(14, s.e14),(15, s.e15),
    (16, s.e16),(17, s.e17),(18, s.e18),(19, s.e19),(20, s.e20),
    (21, s.e21),(22, s.e22),(23, s.e23),(24, s.e24),(25, s.e25),
    (26, s.e26),(27, s.e27),(28, s.e28),(29, s.e29),(30, s.e30),
    (31, s.e31),(32, s.e32),(33, s.e33),(34, s.e34),(35, s.e35),
    (36, s.e36),(37, s.e37),(38, s.e38),(39, s.e39),(40, s.e40),
    (41, s.e41),(42, s.e42),(43, s.e43),(44, s.e44),(45, s.e45),
    (46, s.e46),(47, s.e47),(48, s.e48),(49, s.e49),(50, s.e50)
) AS v(lambda_id, result);

--SPLIT
-- 17 10000 2
WITH data_scan AS NOT MATERIALIZED (
  SELECT
    d.id AS data_id,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e1,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e2
  FROM nums d
  WHERE d.id <= 10000
)
SELECT avg(v.result)
FROM data_scan s
CROSS JOIN LATERAL (VALUES (1, s.e1),(2, s.e2)
) AS v(lambda_id, result);

--SPLIT
-- 17 10000 5
WITH data_scan AS NOT MATERIALIZED (
  SELECT
    d.id AS data_id,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e1,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e2,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e3,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e4,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e5
  FROM nums d
  WHERE d.id <= 10000
)
SELECT avg(v.result)
FROM data_scan s
CROSS JOIN LATERAL (VALUES (1, s.e1),(2, s.e2),(3, s.e3),(4, s.e4),(5, s.e5)
) AS v(lambda_id, result);

--SPLIT
-- 17 10000 10
WITH data_scan AS NOT MATERIALIZED (
  SELECT
    d.id AS data_id,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e01,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e02,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e03,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e04,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e05,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e06,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e07,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e08,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e09,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e10
  FROM nums d
  WHERE d.id <= 10000
)
SELECT avg(v.result)
FROM data_scan s
CROSS JOIN LATERAL (VALUES (01, s.e01),(02, s.e02),(03, s.e03),(04, s.e04),(05, s.e05),
    (06, s.e06),(07, s.e07),(08, s.e08),(09, s.e09),(10, s.e10)
) AS v(lambda_id, result);

--SPLIT
-- 17 10000 20
WITH data_scan AS NOT MATERIALIZED (
  SELECT
    d.id AS data_id,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e01,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e02,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e03,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e04,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e05,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e06,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e07,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e08,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e09,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e10,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e11,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e12,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e13,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e14,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e15,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e16,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e17,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e18,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e19,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e20
  FROM nums d
  WHERE d.id <= 10000
)
SELECT avg(v.result)
FROM data_scan s
CROSS JOIN LATERAL (VALUES (01, s.e01),(02, s.e02),(03, s.e03),(04, s.e04),(05, s.e05),
    (06, s.e06),(07, s.e07),(08, s.e08),(09, s.e09),(10, s.e10),
    (11, s.e11),(12, s.e12),(13, s.e13),(14, s.e14),(15, s.e15),
    (16, s.e16),(17, s.e17),(18, s.e18),(19, s.e19),(20, s.e20)
) AS v(lambda_id, result);

--SPLIT
-- 17 10000 100
WITH data_scan AS NOT MATERIALIZED (
  SELECT
    d.id AS data_id,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e001,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e002,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e003,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e004,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e005,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e006,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e007,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e008,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e009,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e010,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e011,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e012,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e013,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e014,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e015,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e016,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e017,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e018,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e019,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e020,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e021,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e022,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e023,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e024,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e025,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e026,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e027,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e028,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e029,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e030,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e031,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e032,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e033,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e034,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e035,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e036,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e037,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e038,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e039,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e040,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e041,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e042,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e043,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e044,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e045,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e046,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e047,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e048,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e049,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e050,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e051,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e052,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e053,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e054,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e055,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e056,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e057,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e058,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e059,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e060,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e061,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e062,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e063,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e064,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e065,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e066,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e067,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e068,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e069,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e070,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e071,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e072,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e073,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e074,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e075,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e076,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e077,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e078,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e079,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e080,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e081,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e082,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e083,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e084,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e085,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e086,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e087,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e088,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e089,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e090,
    (((abs(d.x + d.y * d.z) * 0.9 + (d.x + d.y * d.z)) + (abs(d.z + d.y * d.x) * 0.9 + (d.z + d.y * d.x))) / 2)::float8 AS e091,
    (((abs(d.x * d.y + d.z) * 0.9 + (d.x * d.y + d.z)) + (abs(d.z * d.y + d.x) * 0.9 + (d.z * d.y + d.x))) / 2)::float8 AS e092,
    (((abs(d.x - d.y + d.z) * 0.9 + (d.x - d.y + d.z)) + (abs(d.z - d.y + d.x) * 0.9 + (d.z - d.y + d.x))) / 2)::float8 AS e093,
    (((abs(d.x * d.z + d.y) * 0.9 + (d.x * d.z + d.y)) + (abs(d.z * d.x + d.y) * 0.9 + (d.z * d.x + d.y))) / 2)::float8 AS e094,
    (((abs((d.x + d.y) * d.z) * 0.9 + ((d.x + d.y) * d.z)) + (abs((d.z + d.y) * d.x) * 0.9 + ((d.z + d.y) * d.x))) / 2)::float8 AS e095,
    (((abs(d.x * d.x + d.y * d.z) * 0.9 + (d.x * d.x + d.y * d.z)) + (abs(d.z * d.z + d.y * d.x) * 0.9 + (d.z * d.z + d.y * d.x))) / 2)::float8 AS e096,
    (((abs(d.x * d.y * d.z) * 0.9 + (d.x * d.y * d.z)) + (abs(d.z * d.y * d.x) * 0.9 + (d.z * d.y * d.x))) / 2)::float8 AS e097,
    (((abs((d.x - d.z) * (d.y + 1.0)) * 0.9 + ((d.x - d.z) * (d.y + 1.0))) + (abs((d.z - d.x) * (d.y + 1.0)) * 0.9 + ((d.z - d.x) * (d.y + 1.0)))) / 2)::float8 AS e098,
    (((abs(d.x + d.y + d.z) * 0.9 + (d.x + d.y + d.z)) + (abs(d.z + d.y + d.x) * 0.9 + (d.z + d.y + d.x))) / 2)::float8 AS e099,
    (((abs(d.x * (d.y - d.z)) * 0.9 + (d.x * (d.y - d.z))) + (abs(d.z * (d.y - d.x)) * 0.9 + (d.z * (d.y - d.x)))) / 2)::float8 AS e100
  FROM nums d
  WHERE d.id <= 10000
)
SELECT avg(v.result)
FROM data_scan s
CROSS JOIN LATERAL (VALUES (001, s.e001),(002, s.e002),(003, s.e003),(004, s.e004),(005, s.e005),
    (006, s.e006),(007, s.e007),(008, s.e008),(009, s.e009),(010, s.e010),
    (011, s.e011),(012, s.e012),(013, s.e013),(014, s.e014),(015, s.e015),
    (016, s.e016),(017, s.e017),(018, s.e018),(019, s.e019),(020, s.e020),
    (021, s.e021),(022, s.e022),(023, s.e023),(024, s.e024),(025, s.e025),
    (026, s.e026),(027, s.e027),(028, s.e028),(029, s.e029),(030, s.e030),
    (031, s.e031),(032, s.e032),(033, s.e033),(034, s.e034),(035, s.e035),
    (036, s.e036),(037, s.e037),(038, s.e038),(039, s.e039),(040, s.e040),
    (041, s.e041),(042, s.e042),(043, s.e043),(044, s.e044),(045, s.e045),
    (046, s.e046),(047, s.e047),(048, s.e048),(049, s.e049),(050, s.e050),
    (051, s.e051),(052, s.e052),(053, s.e053),(054, s.e054),(055, s.e055),
    (056, s.e056),(057, s.e057),(058, s.e058),(059, s.e059),(060, s.e060),
    (061, s.e061),(062, s.e062),(063, s.e063),(064, s.e064),(065, s.e065),
    (066, s.e066),(067, s.e067),(068, s.e068),(069, s.e069),(070, s.e070),
    (071, s.e071),(072, s.e072),(073, s.e073),(074, s.e074),(075, s.e075),
    (076, s.e076),(077, s.e077),(078, s.e078),(079, s.e079),(080, s.e080),
    (081, s.e081),(082, s.e082),(083, s.e083),(084, s.e084),(085, s.e085),
    (086, s.e086),(087, s.e087),(088, s.e088),(089, s.e089),(090, s.e090),
    (091, s.e091),(092, s.e092),(093, s.e093),(094, s.e094),(095, s.e095),
    (096, s.e096),(097, s.e097),(098, s.e098),(099, s.e099),(100, s.e100)
) AS v(lambda_id, result);
