-- recursive CTEs: run with  python3 tests/differential/diff.py --file tests/differential/recursive.sql
WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM cnt WHERE x < 20) SELECT x FROM cnt ORDER BY x
WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM cnt) SELECT x FROM cnt LIMIT 7
WITH RECURSIVE cnt(x) AS (SELECT 5 UNION ALL SELECT x - 1 FROM cnt WHERE x > 0) SELECT SUM(x), COUNT(*), MIN(x), MAX(x) FROM cnt
WITH RECURSIVE fib(a, b) AS (SELECT 0, 1 UNION ALL SELECT b, a + b FROM fib WHERE b < 500) SELECT a FROM fib ORDER BY a
WITH RECURSIVE fact(n, f) AS (SELECT 1, 1 UNION ALL SELECT n + 1, f * (n + 1) FROM fact WHERE n < 15) SELECT n, f FROM fact ORDER BY n
WITH RECURSIVE t(x) AS (SELECT 1 UNION SELECT (x % 5) + 1 FROM t) SELECT x FROM t ORDER BY x
WITH RECURSIVE t(x) AS (SELECT 1 UNION ALL SELECT (x % 5) + 1 FROM t WHERE x < 4) SELECT x FROM t ORDER BY x
WITH RECURSIVE edges(a, b) AS (VALUES (1,2),(2,3),(3,4),(2,5),(5,6),(6,2)), reach(n) AS (SELECT 1 UNION SELECT b FROM edges JOIN reach ON a = n) SELECT n FROM reach ORDER BY n
WITH RECURSIVE edges(a, b) AS (VALUES (1,2),(2,3),(3,4),(2,5),(5,6),(6,2)), path(n, d) AS (SELECT 1, 0 UNION SELECT b, d + 1 FROM edges JOIN path ON a = n WHERE d < 6) SELECT n, MIN(d) FROM path GROUP BY n ORDER BY n
WITH RECURSIVE p(id, parent, name) AS (VALUES (1, 0, 'root'), (2, 1, 'a'), (3, 1, 'b'), (4, 2, 'c'), (5, 4, 'd')), tree(id, depth, path) AS (SELECT id, 0, name FROM p WHERE parent = 0 UNION ALL SELECT p.id, tree.depth + 1, tree.path || '/' || p.name FROM p JOIN tree ON p.parent = tree.id) SELECT id, depth, path FROM tree ORDER BY id
WITH RECURSIVE anc(id) AS (SELECT id FROM t1 WHERE id = 7 UNION SELECT t1.g FROM t1 JOIN anc ON t1.id = anc.id) SELECT id FROM anc ORDER BY id
WITH RECURSIVE nums(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM nums WHERE n < 10) SELECT t1.id, nums.n FROM t1 JOIN nums ON nums.n = t1.g WHERE t1.id < 8 ORDER BY 1, 2
WITH RECURSIVE nums(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM nums WHERE n < 6) SELECT g, COUNT(*) FROM t1 WHERE g IN (SELECT n FROM nums) GROUP BY g ORDER BY g
WITH RECURSIVE s(i, str) AS (SELECT 1, 'a' UNION ALL SELECT i + 1, str || 'a' FROM s WHERE i < 5) SELECT i, str, LENGTH(str) FROM s ORDER BY i
WITH RECURSIVE a(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM a WHERE x < 3), b(y) AS (SELECT x * 10 FROM a) SELECT y FROM b ORDER BY y
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 5) SELECT a.x, b.x FROM c a JOIN c b ON b.x = a.x + 1 ORDER BY 1
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x * 2 FROM c WHERE x < 100) SELECT x, ROW_NUMBER() OVER (ORDER BY x DESC) FROM c ORDER BY x
WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 5) SELECT (SELECT SUM(n) FROM r), (SELECT MAX(n) FROM r)
WITH x(v) AS (SELECT 1 UNION ALL SELECT 2) SELECT v FROM x ORDER BY v
WITH RECURSIVE x(v) AS (SELECT 1 UNION ALL SELECT 2) SELECT v FROM x ORDER BY v
