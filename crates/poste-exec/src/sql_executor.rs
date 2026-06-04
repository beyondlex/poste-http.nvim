//! SQL execution engine for PostgreSQL, MySQL, and SQLite.
//!
//! Uses sqlx for database connectivity and query execution.
//! Returns structured JSON responses compatible with the Lua-side
//! dataset renderer.

use poste_core::{Protocol, Request};
use poste_core::sql_parser;
use crate::response::Response;
use crate::sql_dialect;
use anyhow::Result;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::time::Instant;

/// Execute a SQL request. Dispatches to the appropriate database driver
/// based on `request.protocol`.
pub async fn execute_sql(request: &Request) -> Result<Response> {
    let parsed = sql_parser::parse_sql_request(request)?;

    if parsed.statements.is_empty() {
        anyhow::bail!("No SQL statements found");
    }

    // Check if the first (and only) statement is a USE statement
    if parsed.statements.len() == 1 {
        if let Some(db_name) = sql_parser::detect_use_statement(&parsed.statements[0]) {
            let dialect = sql_dialect::dialect_for(&request.protocol)
                .map(|d| d.name().to_string())
                .unwrap_or_else(|| "unknown".to_string());
            let body = serde_json::to_string(&json!({
                "type": "use",
                "database_name": db_name,
                "is_use_statement": true,
                "connection": parsed.connection,
                "dialect": dialect,
            }))?;
            return Ok(make_response(&request.protocol, &parsed.connection, body, format!("Context → {}", db_name)));
        }
    }

    match request.protocol {
        Protocol::Postgres => execute_postgres(&parsed).await,
        Protocol::Mysql => execute_mysql(&parsed).await,
        Protocol::Sqlite => execute_sqlite(&parsed).await,
        _ => anyhow::bail!("Not a SQL protocol: {:?}", request.protocol),
    }
}

fn make_response(protocol: &Protocol, connection: &str, body: String, status_text: String) -> Response {
    let proto_name = match protocol {
        Protocol::Postgres => "postgres",
        Protocol::Mysql => "mysql",
        Protocol::Sqlite => "sqlite",
        _ => "sql",
    };
    let mut metadata = HashMap::new();
    metadata.insert("dialect".to_string(), proto_name.to_string());

    Response {
        protocol: proto_name.to_string(),
        status: 0,
        status_text,
        latency_ms: 0,
        url: connection.to_string(),
        content_type: "application/json".to_string(),
        headers: Vec::new(),
        body,
        cookies: Vec::new(),
        metadata,
    }
}

/// Result of executing a single SQL statement.
#[derive(Debug)]
struct StatementResult {
    columns: Vec<Value>,
    rows: Vec<Vec<Value>>,
    row_count: usize,
    affected_rows: Option<u64>,
    execution_time_ms: u64,
}

// ---------------------------------------------------------------------------
// PostgreSQL
// ---------------------------------------------------------------------------

async fn execute_postgres(parsed: &sql_parser::SqlParseResult) -> Result<Response> {
    use sqlx::postgres::{PgPoolOptions, PgRow};
    use sqlx::{Column, Row, TypeInfo};

    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&parsed.connection)
        .await?;

    let mut results = Vec::new();
    let total_start = Instant::now();

    for stmt in &parsed.statements {
        // Skip USE statements in multi-statement blocks
        if sql_parser::detect_use_statement(stmt).is_some() {
            continue;
        }

        let stmt_start = Instant::now();
        let upper = stmt.trim().to_uppercase();

        if upper.starts_with("SELECT")
            || upper.starts_with("WITH")
            || upper.starts_with("EXPLAIN")
            || upper.starts_with("SHOW")
            || upper.starts_with("TABLE ")
            || upper.contains("RETURNING")
        {
            // Query that returns rows
            let rows: Vec<PgRow> = sqlx::query(stmt).fetch_all(&pool).await?;
            let elapsed = stmt_start.elapsed().as_millis() as u64;

            // Extract column metadata from first row (or empty if no rows)
            let columns: Vec<Value> = if let Some(first_row) = rows.first() {
                first_row
                    .columns()
                    .iter()
                    .map(|col| {
                        json!({
                            "name": col.name(),
                            "type": col.type_info().name(),
                            "nullable": col.type_info().name() != "BOOL", // simplified
                        })
                    })
                    .collect()
            } else {
                Vec::new()
            };

            let json_rows: Vec<Vec<Value>> = rows
                .iter()
                .map(|row| {
                    (0..row.len())
                        .map(|i| pg_value_to_json(row, i))
                        .collect()
                })
                .collect();

            let row_count = json_rows.len();
            results.push(StatementResult {
                columns,
                rows: json_rows,
                row_count,
                affected_rows: None,
                execution_time_ms: elapsed,
            });
        } else {
            // DML/DDL that affects rows
            let result = sqlx::query(stmt).execute(&pool).await?;
            let elapsed = stmt_start.elapsed().as_millis() as u64;

            results.push(StatementResult {
                columns: Vec::new(),
                rows: Vec::new(),
                row_count: 0,
                affected_rows: Some(result.rows_affected()),
                execution_time_ms: elapsed,
            });
        }
    }

    pool.close().await;
    let total_ms = total_start.elapsed().as_millis() as u64;
    build_response(&Protocol::Postgres, &parsed.connection, &parsed.database, results, total_ms)
}

/// Convert a PostgreSQL row column value to serde_json::Value.
fn pg_value_to_json(row: &sqlx::postgres::PgRow, idx: usize) -> Value {
    use sqlx::{Column, Row, TypeInfo};

    let type_name = row.column(idx).type_info().name();

    match type_name {
        "BOOL" => row.try_get::<Option<bool>, _>(idx)
            .ok().flatten().map(|v| json!(v)).unwrap_or(Value::Null),
        "INT2" => row.try_get::<Option<i16>, _>(idx)
            .ok().flatten().map(|v| json!(v as i64)).unwrap_or(Value::Null),
        "INT4" => row.try_get::<Option<i32>, _>(idx)
            .ok().flatten().map(|v| json!(v as i64)).unwrap_or(Value::Null),
        "INT8" => row.try_get::<Option<i64>, _>(idx)
            .ok().flatten().map(|v| json!(v)).unwrap_or(Value::Null),
        "FLOAT4" => row.try_get::<Option<f32>, _>(idx)
            .ok().flatten().map(|v| json!(v)).unwrap_or(Value::Null),
        "FLOAT8" => row.try_get::<Option<f64>, _>(idx)
            .ok().flatten().map(|v| json!(v)).unwrap_or(Value::Null),
        "JSON" | "JSONB" => {
            // Get as string and try to parse as JSON
            row.try_get::<Option<String>, _>(idx)
                .ok().flatten()
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or(Value::Null)
        }
        _ => {
            // Fall back to string representation
            row.try_get::<Option<String>, _>(idx)
                .ok().flatten().map(|v| json!(v)).unwrap_or(Value::Null)
        }
    }
}

// ---------------------------------------------------------------------------
// MySQL
// ---------------------------------------------------------------------------

async fn execute_mysql(parsed: &sql_parser::SqlParseResult) -> Result<Response> {
    use sqlx::mysql::{MySqlPoolOptions, MySqlRow};
    use sqlx::{Column, Row, TypeInfo};

    let pool = MySqlPoolOptions::new()
        .max_connections(2)
        .connect(&parsed.connection)
        .await?;

    let mut results = Vec::new();
    let total_start = Instant::now();

    for stmt in &parsed.statements {
        if sql_parser::detect_use_statement(stmt).is_some() {
            continue;
        }

        let stmt_start = Instant::now();
        let upper = stmt.trim().to_uppercase();

        if upper.starts_with("SELECT")
            || upper.starts_with("WITH")
            || upper.starts_with("EXPLAIN")
            || upper.starts_with("SHOW")
            || upper.starts_with("DESCRIBE")
            || upper.starts_with("DESC ")
            || upper.contains("RETURNING")
        {
            let rows: Vec<MySqlRow> = sqlx::query(stmt).fetch_all(&pool).await?;
            let elapsed = stmt_start.elapsed().as_millis() as u64;

            let columns: Vec<Value> = if let Some(first_row) = rows.first() {
                first_row
                    .columns()
                    .iter()
                    .map(|col| {
                        json!({
                            "name": col.name(),
                            "type": col.type_info().name(),
                        })
                    })
                    .collect()
            } else {
                Vec::new()
            };

            let json_rows: Vec<Vec<Value>> = rows
                .iter()
                .map(|row| {
                    (0..row.len())
                        .map(|i| mysql_value_to_json(row, i))
                        .collect()
                })
                .collect();

            let row_count = json_rows.len();
            results.push(StatementResult {
                columns,
                rows: json_rows,
                row_count,
                affected_rows: None,
                execution_time_ms: elapsed,
            });
        } else {
            let result = sqlx::query(stmt).execute(&pool).await?;
            let elapsed = stmt_start.elapsed().as_millis() as u64;

            results.push(StatementResult {
                columns: Vec::new(),
                rows: Vec::new(),
                row_count: 0,
                affected_rows: Some(result.rows_affected()),
                execution_time_ms: elapsed,
            });
        }
    }

    pool.close().await;
    let total_ms = total_start.elapsed().as_millis() as u64;
    build_response(&Protocol::Mysql, &parsed.connection, &parsed.database, results, total_ms)
}

/// Convert a MySQL row column value to serde_json::Value.
fn mysql_value_to_json(row: &sqlx::mysql::MySqlRow, idx: usize) -> Value {
    use sqlx::{Column, Row, TypeInfo, ValueRef};

    // Check for NULL first — avoids false negatives from type-specific decoders
    if let Ok(raw) = row.try_get_raw(idx) {
        if raw.is_null() {
            return Value::Null;
        }
    }

    let type_name = row.column(idx).type_info().name();

    match type_name {
        "BOOLEAN" => row.try_get::<Option<bool>, _>(idx)
            .ok().flatten().map(|v| json!(v)).unwrap_or(Value::Null),
        "TINYINT" | "TINYINT UNSIGNED" => {
            // TINYINT(1) is typically used as boolean
            row.try_get::<Option<i8>, _>(idx)
                .ok().flatten()
                .map(|v| json!(v as i64))
                .unwrap_or(Value::Null)
        }
        "SMALLINT" | "SMALLINT UNSIGNED" => row.try_get::<Option<i16>, _>(idx)
            .ok().flatten().map(|v| json!(v as i64)).unwrap_or(Value::Null),
        "INT" | "INT UNSIGNED" | "MEDIUMINT" | "MEDIUMINT UNSIGNED" => row.try_get::<Option<i32>, _>(idx)
            .ok().flatten().map(|v| json!(v as i64)).unwrap_or(Value::Null),
        "BIGINT" | "BIGINT UNSIGNED" => row.try_get::<Option<i64>, _>(idx)
            .ok().flatten().map(|v| json!(v)).unwrap_or(Value::Null),
        "FLOAT" => row.try_get::<Option<f32>, _>(idx)
            .ok().flatten().map(|v| json!(v)).unwrap_or(Value::Null),
        "DOUBLE" => row.try_get::<Option<f64>, _>(idx)
            .ok().flatten().map(|v| json!(v)).unwrap_or(Value::Null),
        "DECIMAL" => row.try_get::<Option<String>, _>(idx)
            .ok().flatten()
            .map(|s| {
                s.parse::<f64>().map(|v| json!(v)).unwrap_or(json!(s))
            })
            .unwrap_or(Value::Null),
        "JSON" => {
            row.try_get::<Option<String>, _>(idx)
                .ok().flatten()
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or(Value::Null)
        }
        // Explicit string types — covers VARCHAR, VAR_STRING, TEXT, CHAR, ENUM, etc.
        // SHOW TABLES returns VAR_STRING which must be matched here.
        "VARCHAR" | "VAR_STRING" | "STRING" | "CHAR" |
        "TEXT" | "TINYTEXT" | "MEDIUMTEXT" | "LONGTEXT" |
        "ENUM" | "SET" => {
            row.try_get::<Option<String>, _>(idx)
                .ok().flatten().map(|v| json!(v)).unwrap_or(Value::Null)
        }
        _ => {
            // Last resort: try String, then bytes, then null
            if let Ok(Some(s)) = row.try_get::<Option<String>, _>(idx) {
                json!(s)
            } else if let Ok(Some(b)) = row.try_get::<Option<Vec<u8>>, _>(idx) {
                json!(String::from_utf8_lossy(&b).to_string())
            } else {
                Value::Null
            }
        }
    }
}

// ---------------------------------------------------------------------------
// SQLite
// ---------------------------------------------------------------------------

async fn execute_sqlite(parsed: &sql_parser::SqlParseResult) -> Result<Response> {
    use sqlx::sqlite::{SqlitePoolOptions, SqliteRow};
    use sqlx::{Column, Row, TypeInfo};

    // Convert connection string to sqlx format
    // Input: "sqlite:///path/to/db.sqlite" or "sqlite://./relative.db" or "sqlite::memory:"
    // sqlx expects: "sqlite:/path/to/db.sqlite" or "sqlite:./relative.db" or "sqlite::memory:"
    let conn_str = normalize_sqlite_connection(&parsed.connection)?;

    let pool: sqlx::Pool<sqlx::Sqlite> = SqlitePoolOptions::new()
        .max_connections(2)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(&conn_str)
        .await
        .map_err(|e| anyhow::anyhow!("SQLite connection failed for '{}': {}", conn_str, e))?;

    let mut results = Vec::new();
    let total_start = Instant::now();

    for stmt in &parsed.statements {
        if sql_parser::detect_use_statement(stmt).is_some() {
            continue;
        }

        let stmt_start = Instant::now();
        let upper = stmt.trim().to_uppercase();

        // SQLite: most statements return results (SELECT, PRAGMA, EXPLAIN)
        if upper.starts_with("SELECT")
            || upper.starts_with("WITH")
            || upper.starts_with("EXPLAIN")
            || upper.starts_with("PRAGMA")
            || upper.starts_with("VALUES")
            || upper.contains("RETURNING")
        {
            let rows: Vec<SqliteRow> = sqlx::query(stmt).fetch_all(&pool).await?;
            let elapsed = stmt_start.elapsed().as_millis() as u64;

            let columns: Vec<Value> = if let Some(first_row) = rows.first() {
                first_row
                    .columns()
                    .iter()
                    .map(|col| {
                        json!({
                            "name": col.name(),
                            "type": col.type_info().name(),
                        })
                    })
                    .collect()
            } else {
                Vec::new()
            };

            let json_rows: Vec<Vec<Value>> = rows
                .iter()
                .map(|row| {
                    (0..row.len())
                        .map(|i| sqlite_value_to_json(row, i))
                        .collect()
                })
                .collect();

            let row_count = json_rows.len();
            results.push(StatementResult {
                columns,
                rows: json_rows,
                row_count,
                affected_rows: None,
                execution_time_ms: elapsed,
            });
        } else {
            let result = sqlx::query(stmt).execute(&pool).await?;
            let elapsed = stmt_start.elapsed().as_millis() as u64;

            results.push(StatementResult {
                columns: Vec::new(),
                rows: Vec::new(),
                row_count: 0,
                affected_rows: Some(result.rows_affected()),
                execution_time_ms: elapsed,
            });
        }
    }

    pool.close().await;
    let total_ms = total_start.elapsed().as_millis() as u64;
    build_response(&Protocol::Sqlite, &parsed.connection, &parsed.database, results, total_ms)
}

/// Normalize SQLite connection string for sqlx.
/// Input formats:
///   - "sqlite:///absolute/path/db.sqlite" → "sqlite:/absolute/path/db.sqlite"
///   - "sqlite://./relative.db" → "sqlite:./relative.db"
///   - "sqlite::memory:" → "sqlite::memory:"
///   - "/path/to/db.sqlite" → "sqlite:/path/to/db.sqlite"
fn normalize_sqlite_connection(conn: &str) -> Result<String> {
    let conn = conn.trim();

    // Already in sqlx format
    if conn.starts_with("sqlite:") && !conn.starts_with("sqlite://") {
        return Ok(conn.to_string());
    }

    // sqlite:///absolute/path → sqlite:/absolute/path
    if let Some(rest) = conn.strip_prefix("sqlite:///") {
        return Ok(format!("sqlite:/{}", rest));
    }

    // sqlite://./relative → sqlite:./relative
    if let Some(rest) = conn.strip_prefix("sqlite://") {
        return Ok(format!("sqlite:{}", rest));
    }

    // Plain path: /path or ./path or just filename
    if conn.starts_with('/') || conn.starts_with("./") || conn.starts_with(":memory:") {
        return Ok(format!("sqlite:{}", conn));
    }

    anyhow::bail!("Invalid SQLite connection string: {}", conn)
}

/// Convert a SQLite row column value to serde_json::Value.
/// SQLite has dynamic typing, so we try multiple types.
fn sqlite_value_to_json(row: &sqlx::sqlite::SqliteRow, idx: usize) -> Value {
    use sqlx::{Row, ValueRef};

    // Check if NULL
    if let Ok(raw) = row.try_get_raw(idx) {
        if raw.is_null() {
            return Value::Null;
        }
    }

    // Try integer first (most common)
    if let Ok(Some(v)) = row.try_get::<Option<i64>, _>(idx) {
        return json!(v);
    }

    // Try float
    if let Ok(Some(v)) = row.try_get::<Option<f64>, _>(idx) {
        return json!(v);
    }

    // Try string (TEXT, BLOB displayed as text)
    if let Ok(Some(v)) = row.try_get::<Option<String>, _>(idx) {
        // Try to parse as JSON
        if let Ok(parsed) = serde_json::from_str::<Value>(&v) {
            return parsed;
        }
        return json!(v);
    }

    // Try bool (SQLite stores as 0/1)
    if let Ok(Some(v)) = row.try_get::<Option<bool>, _>(idx) {
        return json!(v);
    }

    Value::Null
}

// ---------------------------------------------------------------------------
// Shared response building
// ---------------------------------------------------------------------------

fn build_response(
    protocol: &Protocol,
    connection: &str,
    database: &Option<String>,
    results: Vec<StatementResult>,
    total_ms: u64,
) -> Result<Response> {
    let has_rows = results.iter().any(|r| r.row_count > 0);
    let total_rows: usize = results.iter().map(|r| r.row_count).sum();
    let total_affected: u64 = results.iter().filter_map(|r| r.affected_rows).sum();

    let dialect = sql_dialect::dialect_for(protocol)
        .map(|d| d.name().to_string())
        .unwrap_or_else(|| "unknown".to_string());

    let response_type = if has_rows { "resultset" } else { "affected" };

    let json_results: Vec<Value> = results
        .iter()
        .map(|r| {
            json!({
                "columns": r.columns,
                "rows": r.rows,
                "row_count": r.row_count,
                "affected_rows": r.affected_rows,
                "execution_time_ms": r.execution_time_ms,
            })
        })
        .collect();

    let body = serde_json::to_string(&json!({
        "type": response_type,
        "results": json_results,
        "total_results": json_results.len(),
        "total_rows": total_rows,
        "total_affected": total_affected,
        "total_execution_time_ms": total_ms,
        "connection": connection,
        "database": database,
        "dialect": dialect,
    }))?;

    let status_text = if has_rows {
        format!("{} row{} returned in {}ms", total_rows, if total_rows == 1 { "" } else { "s" }, total_ms)
    } else {
        format!("{} row{} affected in {}ms", total_affected, if total_affected == 1 { "" } else { "s" }, total_ms)
    };

    Ok(make_response(protocol, connection, body, status_text))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_sqlite_absolute_path() {
        assert_eq!(
            normalize_sqlite_connection("sqlite:///home/user/db.sqlite").unwrap(),
            "sqlite:/home/user/db.sqlite"
        );
    }

    #[test]
    fn test_normalize_sqlite_relative_path() {
        assert_eq!(
            normalize_sqlite_connection("sqlite://./data.db").unwrap(),
            "sqlite:./data.db"
        );
        assert_eq!(
            normalize_sqlite_connection("sqlite://data.db").unwrap(),
            "sqlite:data.db"
        );
    }

    #[test]
    fn test_normalize_sqlite_memory() {
        assert_eq!(
            normalize_sqlite_connection("sqlite::memory:").unwrap(),
            "sqlite::memory:"
        );
        assert_eq!(
            normalize_sqlite_connection(":memory:").unwrap(),
            "sqlite::memory:"
        );
    }

    #[test]
    fn test_normalize_sqlite_plain_path() {
        assert_eq!(
            normalize_sqlite_connection("/absolute/path.db").unwrap(),
            "sqlite:/absolute/path.db"
        );
        assert_eq!(
            normalize_sqlite_connection("./relative.db").unwrap(),
            "sqlite:./relative.db"
        );
    }

    #[test]
    fn test_normalize_sqlite_already_correct() {
        assert_eq!(
            normalize_sqlite_connection("sqlite:/path.db").unwrap(),
            "sqlite:/path.db"
        );
    }

    #[tokio::test]
    async fn test_sqlite_in_memory() {
        use sqlx::sqlite::SqlitePoolOptions;
        let pool: sqlx::Pool<sqlx::Sqlite> = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();

        let rows: Vec<sqlx::sqlite::SqliteRow> = sqlx::query("SELECT 1 as num")
            .fetch_all(&pool)
            .await
            .unwrap();

        assert_eq!(rows.len(), 1);
        pool.close().await;
    }

    #[tokio::test]
    async fn test_sqlite_file_connection() {
        use sqlx::sqlite::SqlitePoolOptions;
        // Create a temp database
        let db_path = "/tmp/poste_test_exec.db";
        std::process::Command::new("sqlite3")
            .args([db_path, "CREATE TABLE IF NOT EXISTS t (x INT); INSERT OR REPLACE INTO t VALUES (42);"])
            .output()
            .unwrap();

        let url = format!("sqlite:{}", db_path);
        let pool: sqlx::Pool<sqlx::Sqlite> = SqlitePoolOptions::new()
            .max_connections(1)
            .acquire_timeout(std::time::Duration::from_secs(3))
            .connect(&url)
            .await
            .expect(&format!("Failed to connect to {}", url));

        let rows: Vec<sqlx::sqlite::SqliteRow> = sqlx::query("SELECT * FROM t")
            .fetch_all(&pool)
            .await
            .unwrap();

        assert_eq!(rows.len(), 1);
        pool.close().await;
        std::fs::remove_file(db_path).ok();
    }
}
