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
#[derive(Debug, Default)]
struct StatementResult {
    columns: Vec<Value>,
    rows: Vec<Vec<Value>>,
    row_count: usize,
    affected_rows: Option<u64>,
    execution_time_ms: u64,
    error: Option<String>,
    translated_sql: Option<String>,
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
        let rest = trimmed.splitn(2, char::is_whitespace).nth(1)?;
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
            let (exec_stmt, translated_sql) = match translate_pg_mysql_compat(stmt) {
                Some((translated, original)) => {
                    (translated, Some(original))
                }
                None => (stmt.clone(), None),
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
                    translated_sql,
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
                    translated_sql,
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
        "NUMERIC" => {
            let val: Option<rust_decimal::Decimal> = row.try_get::<_, _>(idx).ok().flatten();
            val.map(|v: rust_decimal::Decimal| {
                v.to_string().parse::<f64>().map(|n| json!(n)).unwrap_or(json!(v.to_string()))
            }).unwrap_or(Value::Null)
        }
        "DATE" => {
            if let Ok(Some(v)) = row.try_get::<Option<sqlx::types::chrono::NaiveDate>, _>(idx) {
                json!(v.format("%Y-%m-%d").to_string())
            } else if let Ok(Some(s)) = row.try_get::<Option<String>, _>(idx) {
                json!(s)
            } else if let Ok(Some(b)) = row.try_get::<Option<Vec<u8>>, _>(idx) {
                json!(String::from_utf8_lossy(&b).to_string())
            } else {
                Value::Null
            }
        }
        "TIMESTAMP" => {
            if let Ok(Some(v)) = row.try_get::<Option<sqlx::types::chrono::NaiveDateTime>, _>(idx) {
                json!(v.format("%Y-%m-%d %H:%M:%S%.3f").to_string())
            } else if let Ok(Some(s)) = row.try_get::<Option<String>, _>(idx) {
                json!(s)
            } else if let Ok(Some(b)) = row.try_get::<Option<Vec<u8>>, _>(idx) {
                json!(String::from_utf8_lossy(&b).to_string())
            } else {
                Value::Null
            }
        }
        "TIMESTAMPTZ" => {
            if let Ok(Some(v)) = row.try_get::<Option<sqlx::types::chrono::DateTime<sqlx::types::chrono::Utc>>, _>(idx) {
                json!(v.format("%Y-%m-%d %H:%M:%S%.3f %:z").to_string())
            } else if let Ok(Some(s)) = row.try_get::<Option<String>, _>(idx) {
                json!(s)
            } else if let Ok(Some(b)) = row.try_get::<Option<Vec<u8>>, _>(idx) {
                json!(String::from_utf8_lossy(&b).to_string())
            } else {
                Value::Null
            }
        }
        "TIME" => {
            if let Ok(Some(v)) = row.try_get::<Option<sqlx::types::chrono::NaiveTime>, _>(idx) {
                json!(v.format("%H:%M:%S%.3f").to_string())
            } else if let Ok(Some(s)) = row.try_get::<Option<String>, _>(idx) {
                json!(s)
            } else if let Ok(Some(b)) = row.try_get::<Option<Vec<u8>>, _>(idx) {
                json!(String::from_utf8_lossy(&b).to_string())
            } else {
                Value::Null
            }
        }
        "UUID" => {
            if let Ok(Some(v)) = row.try_get::<Option<sqlx::types::uuid::Uuid>, _>(idx) {
                json!(v.to_string())
            } else if let Ok(Some(s)) = row.try_get::<Option<String>, _>(idx) {
                json!(s)
            } else if let Ok(Some(b)) = row.try_get::<Option<Vec<u8>>, _>(idx) {
                json!(String::from_utf8_lossy(&b).to_string())
            } else {
                Value::Null
            }
        }
        "INET" | "CIDR" => {
            if let Ok(Some(v)) = row.try_get::<Option<sqlx::types::ipnetwork::IpNetwork>, _>(idx) {
                json!(v.to_string())
            } else if let Ok(Some(s)) = row.try_get::<Option<String>, _>(idx) {
                json!(s)
            } else if let Ok(Some(b)) = row.try_get::<Option<Vec<u8>>, _>(idx) {
                json!(String::from_utf8_lossy(&b).to_string())
            } else {
                Value::Null
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
            let stmt_start = Instant::now();
            pool.close().await;
            current_url = replace_database_in_url(&current_url, &db_name);
            pool = MySqlPoolOptions::new()
                .max_connections(2)
                .connect(&current_url)
                .await
                .map_err(|e| anyhow::anyhow!("Failed to connect to database '{}': {}", db_name, e))?;
            continue;
        }

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
                    translated_sql: None,
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
                    translated_sql: None,
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
        "DECIMAL" => {
            let val: Option<rust_decimal::Decimal> = row.try_get::<_, _>(idx).ok().flatten();
            val.map(|v: rust_decimal::Decimal| {
                v.to_string().parse::<f64>().map(|n| json!(n)).unwrap_or(json!(v.to_string()))
            }).unwrap_or(Value::Null)
        }
        "DATE" => {
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
            match row.try_get::<Option<sqlx::types::chrono::NaiveDateTime>, _>(idx) {
                Ok(Some(v)) => json!(v.format("%Y-%m-%d %H:%M:%S%.3f").to_string()),
                Ok(None) => Value::Null,
                Err(_) => Value::Null,
            }
        }
        "TIMESTAMP" => {
            // MySQL TIMESTAMP → chrono::DateTime<Utc> (stored as UTC)
            match row.try_get::<Option<sqlx::types::chrono::DateTime<sqlx::types::chrono::Utc>>, _>(idx) {
                Ok(Some(v)) => json!(v.format("%Y-%m-%d %H:%M:%S%.3f").to_string()),
                Ok(None) => Value::Null,
                Err(_) => Value::Null,
            }
        }
        "TIME" => {
            match row.try_get::<Option<sqlx::types::chrono::NaiveTime>, _>(idx) {
                Ok(Some(v)) => json!(v.format("%H:%M:%S%.3f").to_string()),
                Ok(None) => Value::Null,
                Err(_) => Value::Null,
            }
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
                    translated_sql: None,
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
                    translated_sql: None,
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

/// Replace the database name in a connection URL.
/// Used to handle USE statements by reconnecting to the target database.
fn replace_database_in_url(url: &str, new_db: &str) -> String {
    // Find the scheme separator
    if let Some(scheme_end) = url.find("://") {
        let after_scheme = &url[scheme_end + 3..];
        // Find the last '/' which separates host:port from database
        if let Some(last_slash) = after_scheme.rfind('/') {
            let base = &url[..scheme_end + 3 + last_slash + 1];
            return format!("{}{}", base, new_db);
        }
        // No database part yet — append /newdb
        return format!("{}/{}", url, new_db);
    }
    // Not a standard URL — return as-is
    url.to_string()
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
