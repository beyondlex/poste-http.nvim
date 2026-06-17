//! SQL execution engine for PostgreSQL, MySQL, and SQLite.
//!
//! Uses sqlx for database connectivity and query execution.
//! Returns structured JSON responses compatible with the Lua-side
//! dataset renderer.

use poste_core::{replace_database_in_url, Protocol, Request};
use poste_core::sql_parser;
use crate::response::Response;
use crate::sql_dialect;
use anyhow::Result;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::time::Instant;

// ---------------------------------------------------------------------------
// Shared helpers for row-to-JSON value conversion
// ---------------------------------------------------------------------------

/// Convert `Option<T>` into a JSON `Value`, using `Null` for `None`.
fn opt_json<T: serde::Serialize>(v: Option<T>) -> Value {
    v.map(|v| json!(v)).unwrap_or(Value::Null)
}

/// Fallback: try `String`, then `Vec<u8>` (displayed as text), then `Null`.
fn string_fallback(s: Option<String>, b: Option<Vec<u8>>) -> Value {
    if let Some(s) = s {
        json!(s)
    } else if let Some(b) = b {
        json!(String::from_utf8_lossy(&b).to_string())
    } else {
        Value::Null
    }
}

/// Try a chrono `NaiveDate`, then fall through to `string_fallback`.
fn date_fallback(try_date: Option<sqlx::types::chrono::NaiveDate>, s: Option<String>, b: Option<Vec<u8>>) -> Value {
    if let Some(v) = try_date {
        json!(v.format("%Y-%m-%d").to_string())
    } else {
        string_fallback(s, b)
    }
}

/// Try a chrono `NaiveDateTime`, then fall through to `string_fallback`.
fn datetime_fallback(v: Option<sqlx::types::chrono::NaiveDateTime>, s: Option<String>, b: Option<Vec<u8>>) -> Value {
    if let Some(v) = v {
        json!(v.format("%Y-%m-%d %H:%M:%S%.3f").to_string())
    } else {
        string_fallback(s, b)
    }
}

/// Try a chrono `DateTime<Utc>`, then fall through to `string_fallback`.
fn timestamptz_fallback(v: Option<sqlx::types::chrono::DateTime<sqlx::types::chrono::Utc>>, s: Option<String>, b: Option<Vec<u8>>) -> Value {
    if let Some(v) = v {
        json!(v.format("%Y-%m-%d %H:%M:%S%.3f %:z").to_string())
    } else {
        string_fallback(s, b)
    }
}

/// Try a chrono `NaiveTime`, then fall through to `string_fallback`.
fn time_fallback(v: Option<sqlx::types::chrono::NaiveTime>, s: Option<String>, b: Option<Vec<u8>>) -> Value {
    if let Some(v) = v {
        json!(v.format("%H:%M:%S%.3f").to_string())
    } else {
        string_fallback(s, b)
    }
}

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
#[derive(Debug, Default)]
struct StatementResult {
    columns: Vec<Value>,
    rows: Vec<Vec<Value>>,
    row_count: usize,
    affected_rows: Option<u64>,
    execution_time_ms: u64,
    error: Option<String>,
    connection: Option<String>,
    translated_sql: Option<String>,
    original_sql: Option<String>,
}

// ---------------------------------------------------------------------------
// PostgreSQL
// ---------------------------------------------------------------------------

/// Translate MySQL-isms (SHOW TABLES, DESC table) to PostgreSQL information_schema queries.
/// Returns (translated_sql, original_sql) if translation occurred.
fn translate_pg_mysql_compat(stmt: &str) -> Option<(String, String)> {
    let upper = stmt.trim().to_uppercase();
    let trimmed = stmt.trim();

    if upper == "SHOW TABLES" || upper == "SHOW TABLES;" {
        let sql = "\
            SELECT table_name AS \"Table\", table_type AS \"Type\" \
            FROM information_schema.tables \
            WHERE table_schema = 'public' \
            ORDER BY table_name"
            .to_string();
        return Some((sql, trimmed.to_string()));
    }

    if upper.starts_with("DESC ") || upper.starts_with("DESCRIBE ") {
        let (_, rest) = trimmed.split_once(char::is_whitespace)?;
        // Strip trailing semicolon and whitespace
        let table_name = rest.trim_end_matches(';').trim_end().trim_start_matches('"').trim_end_matches('"');
        if table_name.is_empty() {
            return None;
        }
        // Handle schema-qualified: schema.table_name
        let (schema, table) = if let Some(dot) = table_name.rfind('.') {
            let s = table_name[..dot].trim_matches('"');
            let t = table_name[dot + 1..].trim_matches('"');
            (s.to_string(), t.to_string())
        } else {
            ("public".to_string(), table_name.to_string())
        };
        let schema_escaped = schema.replace('\'', "''");
        let table_escaped = table.replace('\'', "''");
        let sql_inlined = format!(
            "SELECT c.column_name AS \"Column\", c.data_type AS \"Type\", \
             c.is_nullable AS \"Nullable\", c.column_default AS \"Default\", \
             CASE WHEN pk.column_name IS NOT NULL THEN 'PRI' ELSE '' END AS \"Key\" \
             FROM information_schema.columns c \
             LEFT JOIN ( \
               SELECT kcu.column_name \
               FROM information_schema.table_constraints tc \
               JOIN information_schema.key_column_usage kcu \
                 ON tc.constraint_name = kcu.constraint_name \
               WHERE tc.table_schema = '{schema_escaped}' AND tc.table_name = '{table_escaped}' \
                 AND tc.constraint_type = 'PRIMARY KEY' \
             ) pk ON c.column_name = pk.column_name \
             WHERE c.table_schema = '{schema_escaped}' AND c.table_name = '{table_escaped}' \
             ORDER BY c.ordinal_position"
        );
        return Some((sql_inlined, trimmed.to_string()));
    }

    None
}

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
        if sql_parser::detect_use_statement(stmt).is_some() {
            continue;
        }

        let stmt_result: anyhow::Result<StatementResult> = async {
            let stmt_start = Instant::now();
            let (exec_stmt, translated_sql, original_sql) = match translate_pg_mysql_compat(stmt) {
                Some((translated, original)) => {
                    (translated.clone(), Some(translated), Some(original))
                }
                None => (stmt.clone(), None, None),
            };
            let upper = exec_stmt.trim().to_uppercase();

            if upper.starts_with("SELECT")
                || upper.starts_with("WITH")
                || upper.starts_with("EXPLAIN")
                || upper.starts_with("SHOW")
                || upper.starts_with("TABLE ")
                || upper.contains("RETURNING")
            {
                let rows: Vec<PgRow> = sqlx::query(&exec_stmt).fetch_all(&pool).await?;
                let elapsed = stmt_start.elapsed().as_millis() as u64;

                let columns: Vec<Value> = if let Some(first_row) = rows.first() {
                    first_row
                        .columns()
                        .iter()
                        .map(|col| {
                            json!({
                                "name": col.name(),
                                "type": col.type_info().name(),
                                "nullable": col.type_info().name() != "BOOL",
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

                Ok(StatementResult {
                    columns,
                    rows: json_rows,
                    row_count,
                    affected_rows: None,
                    execution_time_ms: elapsed,
                    error: None,
                    connection: None,
                    translated_sql,
                    original_sql,
                })
            } else {
                let result = sqlx::query(&exec_stmt).execute(&pool).await?;
                let elapsed = stmt_start.elapsed().as_millis() as u64;

                Ok(StatementResult {
                    columns: Vec::new(),
                    rows: Vec::new(),
                    row_count: 0,
                    affected_rows: Some(result.rows_affected()),
                    execution_time_ms: elapsed,
                    error: None,
                    connection: None,
                    translated_sql,
                    original_sql,
                })
            }
        }.await;

        match stmt_result {
            Ok(sr) => results.push(sr),
            Err(e) => {
                results.push(StatementResult {
                    error: Some(format!("{:#}", e)),
                    ..Default::default()
                });
            }
        }
    }

    pool.close().await;
    let total_ms = total_start.elapsed().as_millis() as u64;
    build_response(&Protocol::Postgres, &parsed.connection, &parsed.database, results, total_ms)
}

// ---------------------------------------------------------------------------
// PostgreSQL value conversion
// ---------------------------------------------------------------------------

/// Convert a PostgreSQL row column value to serde_json::Value.
fn pg_value_to_json(row: &sqlx::postgres::PgRow, idx: usize) -> Value {
    use sqlx::{Column, Row, TypeInfo, ValueRef};

    // Check for NULL first — avoids type decode failures on nullable columns
    if let Ok(raw) = row.try_get_raw(idx) {
        if raw.is_null() {
            return Value::Null;
        }
    }

    let type_name = row.column(idx).type_info().name();

    match type_name {
        "BOOL" => opt_json(row.try_get::<Option<bool>, _>(idx).ok().flatten()),
        "INT2" => opt_json(row.try_get::<Option<i16>, _>(idx).ok().flatten().map(|v| v as i64)),
        "INT4" => opt_json(row.try_get::<Option<i32>, _>(idx).ok().flatten().map(|v| v as i64)),
        "INT8" => opt_json(row.try_get::<Option<i64>, _>(idx).ok().flatten()),
        "FLOAT4" => opt_json(row.try_get::<Option<f32>, _>(idx).ok().flatten()),
        "FLOAT8" => opt_json(row.try_get::<Option<f64>, _>(idx).ok().flatten()),
        "NUMERIC" => {
            let val: Option<rust_decimal::Decimal> = row.try_get::<_, _>(idx).ok().flatten();
            val.map(|v: rust_decimal::Decimal| {
                v.to_string().parse::<f64>().map(|n| json!(n)).unwrap_or(json!(v.to_string()))
            }).unwrap_or(Value::Null)
        }
        "DATE" => date_fallback(
            row.try_get::<Option<sqlx::types::chrono::NaiveDate>, _>(idx).ok().flatten(),
            row.try_get::<Option<String>, _>(idx).ok().flatten(),
            row.try_get::<Option<Vec<u8>>, _>(idx).ok().flatten(),
        ),
        "TIMESTAMP" => datetime_fallback(
            row.try_get::<Option<sqlx::types::chrono::NaiveDateTime>, _>(idx).ok().flatten(),
            row.try_get::<Option<String>, _>(idx).ok().flatten(),
            row.try_get::<Option<Vec<u8>>, _>(idx).ok().flatten(),
        ),
        "TIMESTAMPTZ" => timestamptz_fallback(
            row.try_get::<Option<sqlx::types::chrono::DateTime<sqlx::types::chrono::Utc>>, _>(idx).ok().flatten(),
            row.try_get::<Option<String>, _>(idx).ok().flatten(),
            row.try_get::<Option<Vec<u8>>, _>(idx).ok().flatten(),
        ),
        "TIME" => time_fallback(
            row.try_get::<Option<sqlx::types::chrono::NaiveTime>, _>(idx).ok().flatten(),
            row.try_get::<Option<String>, _>(idx).ok().flatten(),
            row.try_get::<Option<Vec<u8>>, _>(idx).ok().flatten(),
        ),
        "UUID" => {
            if let Ok(Some(v)) = row.try_get::<Option<sqlx::types::uuid::Uuid>, _>(idx) {
                json!(v.to_string())
            } else {
                string_fallback(
                    row.try_get::<Option<String>, _>(idx).ok().flatten(),
                    row.try_get::<Option<Vec<u8>>, _>(idx).ok().flatten(),
                )
            }
        }
        "INET" | "CIDR" => {
            if let Ok(Some(v)) = row.try_get::<Option<sqlx::types::ipnetwork::IpNetwork>, _>(idx) {
                json!(v.to_string())
            } else {
                string_fallback(
                    row.try_get::<Option<String>, _>(idx).ok().flatten(),
                    row.try_get::<Option<Vec<u8>>, _>(idx).ok().flatten(),
                )
            }
        }
        "JSON" | "JSONB" => {
            // sqlx requires the Json<T> wrapper for JSON/JSONB columns,
            // NOT try_get::<String> which fails silently.
            if let Ok(Some(json_val)) = row.try_get::<Option<sqlx::types::Json<Value>>, _>(idx) {
                json_val.0
            } else if let Ok(Some(s)) = row.try_get::<Option<String>, _>(idx) {
                serde_json::from_str(&s).unwrap_or(json!(s))
            } else {
                Value::Null
            }
        }
        _ => {
            // Fall back to string representation
            string_fallback(
                row.try_get::<Option<String>, _>(idx).ok().flatten(),
                row.try_get::<Option<Vec<u8>>, _>(idx).ok().flatten(),
            )
        }
    }
}

// ---------------------------------------------------------------------------
// MySQL
// ---------------------------------------------------------------------------

async fn execute_mysql(parsed: &sql_parser::SqlParseResult) -> Result<Response> {
    use sqlx::mysql::{MySqlPoolOptions, MySqlRow};
    use sqlx::{Column, Row, TypeInfo};

    let mut current_url = parsed.connection.clone();
    let mut pool = MySqlPoolOptions::new()
        .max_connections(2)
        .connect(&current_url)
        .await?;

    let mut results = Vec::new();
    let total_start = Instant::now();

    for stmt in &parsed.statements {
        if let Some(db_name) = sql_parser::detect_use_statement(stmt) {
            let _stmt_start = Instant::now();
            pool.close().await;
            current_url = replace_database_in_url(&current_url, &db_name);
            pool = MySqlPoolOptions::new()
                .max_connections(2)
                .connect(&current_url)
                .await
                .map_err(|e| anyhow::anyhow!("Failed to connect to database '{}': {}", db_name, e))?;
            continue;
        }

        let stmt_conn = current_url.clone();
        let stmt_result: anyhow::Result<StatementResult> = async {
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

                Ok(StatementResult {
                    columns,
                    rows: json_rows,
                    row_count,
                    affected_rows: None,
                    execution_time_ms: elapsed,
                    error: None,
                    connection: Some(stmt_conn.clone()),
                    translated_sql: None,
                    original_sql: None,
                })
            } else {
                let result = sqlx::query(stmt).execute(&pool).await?;
                let elapsed = stmt_start.elapsed().as_millis() as u64;

                Ok(StatementResult {
                    columns: Vec::new(),
                    rows: Vec::new(),
                    row_count: 0,
                    affected_rows: Some(result.rows_affected()),
                    execution_time_ms: elapsed,
                    error: None,
                    connection: Some(stmt_conn.clone()),
                    translated_sql: None,
                    original_sql: None,
                })
            }
        }.await;

        match stmt_result {
            Ok(mut sr) => {
                sr.connection = Some(current_url.clone());
                results.push(sr);
            }
            Err(e) => {
                results.push(StatementResult {
                    error: Some(format!("{:#}", e)),
                    connection: Some(current_url.clone()),
                    ..Default::default()
                });
            }
        }
    }

    pool.close().await;
    let total_ms = total_start.elapsed().as_millis() as u64;
    build_response(&Protocol::Mysql, &parsed.connection, &parsed.database, results, total_ms)
}
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
        "BOOLEAN" => opt_json(row.try_get::<Option<bool>, _>(idx).ok().flatten()),
        "TINYINT" => {
            // TINYINT(1) is typically used as boolean
            opt_json(row.try_get::<Option<i8>, _>(idx).ok().flatten().map(|v| v as i64))
        }
        "TINYINT UNSIGNED" => {
            opt_json(row.try_get::<Option<u8>, _>(idx).ok().flatten().map(|v| v as i64))
        }
        "SMALLINT" => {
            opt_json(row.try_get::<Option<i16>, _>(idx).ok().flatten().map(|v| v as i64))
        }
        "SMALLINT UNSIGNED" => {
            opt_json(row.try_get::<Option<u16>, _>(idx).ok().flatten().map(|v| v as i64))
        }
        "MEDIUMINT" | "MEDIUMINT UNSIGNED" | "INT" => {
            opt_json(row.try_get::<Option<i32>, _>(idx).ok().flatten().map(|v| v as i64))
        }
        "INT UNSIGNED" => {
            opt_json(row.try_get::<Option<u32>, _>(idx).ok().flatten().map(|v| v as i64))
        }
        "BIGINT" => {
            opt_json(row.try_get::<Option<i64>, _>(idx).ok().flatten())
        }
        "BIGINT UNSIGNED" => {
            // Serialize as string to avoid u64 precision loss in JSON
            if let Ok(Some(v)) = row.try_get::<Option<u64>, _>(idx) {
                json!(v.to_string())
            } else {
                Value::Null
            }
        }
        "FLOAT" => opt_json(row.try_get::<Option<f32>, _>(idx).ok().flatten()),
        "DOUBLE" => opt_json(row.try_get::<Option<f64>, _>(idx).ok().flatten()),
        "DECIMAL" => {
            let val: Option<rust_decimal::Decimal> = row.try_get::<_, _>(idx).ok().flatten();
            val.map(|v: rust_decimal::Decimal| {
                v.to_string().parse::<f64>().map(|n| json!(n)).unwrap_or(json!(v.to_string()))
            }).unwrap_or(Value::Null)
        }
        "DATE" => {
            // MySQL DATE: try NaiveDate, then NaiveDateTime (no String fallback)
            if let Ok(Some(v)) = row.try_get::<Option<sqlx::types::chrono::NaiveDate>, _>(idx) {
                json!(v.format("%Y-%m-%d").to_string())
            } else if let Ok(Some(v)) = row.try_get::<Option<sqlx::types::chrono::NaiveDateTime>, _>(idx) {
                json!(v.format("%Y-%m-%d").to_string())
            } else {
                Value::Null
            }
        }
        "DATETIME" => {
            // MySQL DATETIME → chrono::NaiveDateTime
            opt_json(row.try_get::<Option<sqlx::types::chrono::NaiveDateTime>, _>(idx).ok().flatten()
                .map(|v| v.format("%Y-%m-%d %H:%M:%S%.3f").to_string()))
        }
        "TIMESTAMP" => {
            // MySQL TIMESTAMP → chrono::DateTime<Utc> (stored as UTC)
            opt_json(row.try_get::<Option<sqlx::types::chrono::DateTime<sqlx::types::chrono::Utc>>, _>(idx).ok().flatten()
                .map(|v| v.format("%Y-%m-%d %H:%M:%S%.3f").to_string()))
        }
        "TIME" => {
            opt_json(row.try_get::<Option<sqlx::types::chrono::NaiveTime>, _>(idx).ok().flatten()
                .map(|v| v.format("%H:%M:%S%.3f").to_string()))
        }
        "JSON" => {
            // Try Json<Value> wrapper first (sqlx native), fall back to String
            if let Ok(Some(json_val)) = row.try_get::<Option<sqlx::types::Json<Value>>, _>(idx) {
                json_val.0
            } else if let Ok(Some(s)) = row.try_get::<Option<String>, _>(idx) {
                serde_json::from_str(&s).unwrap_or(json!(s))
            } else if let Ok(Some(b)) = row.try_get::<Option<Vec<u8>>, _>(idx) {
                let s = String::from_utf8_lossy(&b);
                serde_json::from_str(&s).unwrap_or(json!(s.to_string()))
            } else {
                Value::Null
            }
        }
        // Explicit string types — covers VARCHAR, VAR_STRING, TEXT, CHAR, ENUM, etc.
        // SHOW TABLES returns VAR_STRING which must be matched here.
        "VARCHAR" | "VAR_STRING" | "STRING" | "CHAR" |
        "TEXT" | "TINYTEXT" | "MEDIUMTEXT" | "LONGTEXT" |
        "ENUM" | "SET" => {
            opt_json(row.try_get::<Option<String>, _>(idx).ok().flatten())
        }
        _ => {
            // Last resort: try String, then bytes, then null
            string_fallback(
                row.try_get::<Option<String>, _>(idx).ok().flatten(),
                row.try_get::<Option<Vec<u8>>, _>(idx).ok().flatten(),
            )
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

        let stmt_result: anyhow::Result<StatementResult> = async {
            let stmt_start = Instant::now();
            let upper = stmt.trim().to_uppercase();

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

                Ok(StatementResult {
                    columns,
                    rows: json_rows,
                    row_count,
                    affected_rows: None,
                    execution_time_ms: elapsed,
                    error: None,
                    connection: None,
                    translated_sql: None,
                    original_sql: None,
                })
            } else {
                let result = sqlx::query(stmt).execute(&pool).await?;
                let elapsed = stmt_start.elapsed().as_millis() as u64;

                Ok(StatementResult {
                    columns: Vec::new(),
                    rows: Vec::new(),
                    row_count: 0,
                    affected_rows: Some(result.rows_affected()),
                    execution_time_ms: elapsed,
                    error: None,
                    connection: None,
                    translated_sql: None,
                    original_sql: None,
                })
            }
        }.await;

        match stmt_result {
            Ok(sr) => results.push(sr),
            Err(e) => {
                results.push(StatementResult {
                    error: Some(format!("{:#}", e)),
                    ..Default::default()
                });
            }
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
pub(crate) fn normalize_sqlite_connection(conn: &str) -> Result<String> {
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
    let has_error = results.iter().any(|r| r.error.is_some());
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
            let mut obj = json!({
                "columns": r.columns,
                "rows": r.rows,
                "row_count": r.row_count,
                "affected_rows": r.affected_rows,
                "execution_time_ms": r.execution_time_ms,
            });
            if let Some(ref err) = r.error {
                obj["error"] = json!(err);
            }
            if let Some(ref sql) = r.translated_sql {
                obj["translated_sql"] = json!(sql);
            }
            if let Some(ref sql) = r.original_sql {
                obj["original_sql"] = json!(sql);
            }
            if let Some(ref conn) = r.connection {
                obj["connection"] = json!(conn);
            }
            obj
        })
        .collect();

    let mut body_obj = json!({
        "type": response_type,
        "results": json_results,
        "total_results": json_results.len(),
        "total_rows": total_rows,
        "total_affected": total_affected,
        "total_execution_time_ms": total_ms,
        "connection": connection,
        "database": database.clone().unwrap_or_default(),
        "dialect": dialect,
    });
    if has_error {
        body_obj["has_error"] = json!(true);
    }

    let body = serde_json::to_string(&body_obj)?;

    let status_text = if has_rows {
        format!("{} row{} returned in {}ms", total_rows, if total_rows == 1 { "" } else { "s" }, total_ms)
    } else if total_affected > 0 {
        format!("{} row{} affected in {}ms", total_affected, if total_affected == 1 { "" } else { "s" }, total_ms)
    } else {
        format!("Query OK in {}ms", total_ms)
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
