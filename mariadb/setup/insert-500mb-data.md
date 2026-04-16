# How to Insert 500MB of Data into MySQL

## Method: Exponential Doubling

This method creates data by repeatedly doubling the rows in a table, which is much faster than inserting rows one by one.

## Steps

### 1. Create Database and Table

```sql
CREATE DATABASE IF NOT EXISTS testdb;
USE testdb;

CREATE TABLE big_table (
    id INT AUTO_INCREMENT PRIMARY KEY,
    col1 VARCHAR(255),
    col2 VARCHAR(255),
    col3 TEXT,
    col4 TEXT
);
```

### 2. Seed Initial Rows

```sql
INSERT INTO testdb.big_table (col1, col2, col3, col4) VALUES
(MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8)),
(MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8)),
(MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8)),
(MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8));
```

### 3. Double the Data Repeatedly

Each INSERT doubles the number of rows:

```sql
-- Each of these doubles the row count
INSERT INTO big_table (col1, col2, col3, col4)
SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8)
FROM big_table;
```

Run this command multiple times:

| Iteration | Rows     | Approximate Size |
|-----------|----------|------------------|
| Start     | 4        | ~2 KB            |
| 1         | 8        | ~4 KB            |
| 2         | 16       | ~8 KB            |
| ...       | ...      | ...              |
| 15        | 131,072  | ~83 MB           |
| 17        | 524,288  | ~329 MB          |
| 18        | 786,432  | ~493 MB          |

### 4. Verify Size

```sql
ANALYZE TABLE big_table;

SELECT COUNT(*) as row_count FROM testdb.big_table;

SELECT
    table_name,
    ROUND((data_length + index_length) / 1024 / 1024, 2) AS size_mb
FROM information_schema.tables
WHERE table_schema = 'testdb';
```

## Why This Works

1. **Exponential Growth**: Each INSERT doubles the data, so 18 iterations creates 2^18 = 262,144x the original data
2. **Random Data**: `MD5(RAND())` generates unique 32-character hex strings
3. **TEXT Columns**: `REPEAT(MD5(RAND()), 8)` creates 256-character strings, increasing row size
4. **Bulk Insert**: `INSERT ... SELECT` is much faster than individual INSERT statements

## Row Size Calculation

Each row contains approximately:
- `id`: 4 bytes (INT)
- `col1`: ~32 bytes (MD5 hash)
- `col2`: ~32 bytes (MD5 hash)
- `col3`: ~256 bytes (8x MD5 hash)
- `col4`: ~256 bytes (8x MD5 hash)
- Row overhead: ~20 bytes

**Total per row: ~600 bytes**

To reach 500MB: `500 * 1024 * 1024 / 600 ≈ 873,000 rows`

## Complete Script

```sql
CREATE DATABASE IF NOT EXISTS testdb;
USE testdb;

DROP TABLE IF EXISTS big_table;
CREATE TABLE big_table (
    id INT AUTO_INCREMENT PRIMARY KEY,
    col1 VARCHAR(255),
    col2 VARCHAR(255),
    col3 TEXT,
    col4 TEXT
);

-- Seed data
INSERT INTO big_table (col1, col2, col3, col4) VALUES
(MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8)),
(MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8)),
(MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8)),
(MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8));

-- Double 18 times to reach ~500MB
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;
INSERT INTO big_table (col1, col2, col3, col4) SELECT MD5(RAND()), MD5(RAND()), REPEAT(MD5(RAND()), 8), REPEAT(MD5(RAND()), 8) FROM big_table;

-- Verify
use testdb;
ANALYZE TABLE big_table;
SELECT COUNT(*) as row_count FROM testdb.big_table;
SELECT table_name, ROUND((data_length + index_length) / 1024 / 1024, 2) AS size_mb
FROM information_schema.tables WHERE table_schema = 'testdb';
```
