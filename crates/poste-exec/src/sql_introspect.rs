//! Database introspection queries.
//!
//! Provides structured introspection of database metadata: databases, schemas,
//! tables, columns, and indexes. Uses the `Dialect` trait from `sql_dialect.rs`
//! for SQL generation and handles per-dialect parameter binding differences.

use anyhow::Result;
use serde_json::{json, Value};

use crate::sql_dialect::{MysqlDialect, PostgresDialect, SqliteDialect};
use crate::sql_executor::normalize_sqlite_connection;

/// The type of introspection query to execute.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntrospectType {
    Databases,
    Schemas,
    Tables,
    Columns,
    Indexes,
}

impl IntrospectType {
    /// Parse an introspect type from a string.
    pub fn from_str(s: &str) -> Result<Self> {
        match s.to_lowercase().as_str() {
            "databases" => Ok(Self::Databases),
            "schemas" => Ok(Self::Schemas),
            "tables" => Ok(Self::Tables),
            "columns" => Ok(Self::Columns),
            "indexes" => Ok(Self::Indexes),
            _ => anyhow::bail!(
                "Unknown introspect type: '{}'. Expected: databases, schemas, tables, columns, indexes",
                s
            ),
        }
    }

    /// Return the string representation.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Databases => "databases",
            Self::Schemas => "schemas",
            Self::Tables => "tables",
            Self::Columns => "columns",
            Self::Indexes => "indexes",
        }
    }
}

/// Parameters for an introspection query.
pub struct IntrospectParams {
    pub connection_url: String,
    pub dialect_name: String,
    pub introspect_type: IntrospectType,
    pub schema: Option<String>,
    pub table: Option<String>,
}

/// Execute an introspection query and return structured JSON.
pub async fn introspect(params: &IntrospectParams) -> Result<Value> {
    match params.dialect_name.as_str() {
        "postgres" => introspect_postgres(params).await,
        "mysql" => introspect_mysql(params).await,
        "sqlite" => introspect_sqlite(params).await,
        other => anyhow::bail!("Unknown dialect: {}", other),
    }
}

// ---------------------------------------------------------------------------
// PostgreSQL
// ---------------------------------------------------------------------------

async fn introspect_postgres(params: &IntrospectParams) -> Result<Value> {
    use sqlx::postgres::PgPoolOptions;
    use sqlx::Row;

    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&params.connection_url)
        .await?;

    let dialect = PostgresDialect;
    use crate::sql_dialect::Dialect;

    let items: Vec<Value> = match params.introspect_type {
        IntrospectType::Databases => {
            let sql = dialect.list_databases();
            let rows = sqlx::query(sql).fetch_all(&pool).await?;
            rows.iter()
                .map(|row| {
                    json!({ "name": row.get::<String, _>("datname") })
                })
                .collect()
        }
        IntrospectType::Schemas => {
            let sql = dialect.list_schemas().unwrap();
            let rows = sqlx::query(sql).fetch_all(&pool).await?;
            rows.iter()
                .map(|row| {
                    json!({ "name": row.get::<String, _>("schema_name") })
                })
                .collect()
        }
        IntrospectType::Tables => {
            let schema = params.schema.as_deref().unwrap_or("public");
            let sql = dialect.list_tables();
            let rows = sqlx::query(sql).bind(schema).fetch_all(&pool).await?;
            rows.iter()
                .map(|row| {
                    json!({
                        "name": row.get::<String, _>("table_name"),
                        "type": row.get::<String, _>("table_type"),
                    })
                })
                .collect()
        }
        IntrospectType::Columns => {
            let schema = params.schema.as_deref().unwrap_or("public");
            let table = params
                .table
                .as_deref()
                .ok_or_else(|| anyhow::anyhow!("table parameter required for columns introspection"))?;
            let sql = dialect.list_columns();
            let rows = sqlx::query(sql)
                .bind(schema)
                .bind(table)
                .fetch_all(&pool)
                .await?;
            rows.iter()
                .map(|row| {
                    let char_max_len: Option<i32> = row.get("character_maximum_length");
                    json!({
                        "name": row.get::<String, _>("column_name"),
                        "type": row.get::<String, _>("data_type"),
                        "nullable": row.get::<String, _>("is_nullable") == "YES",
                        "default": row.get::<Option<String>, _>("column_default"),
                        "max_length": char_max_len,
                    })
                })
                .collect()
        }
        IntrospectType::Indexes => {
            let schema = params.schema.as_deref().unwrap_or("public");
            let table = params
                .table
                .as_deref()
                .ok_or_else(|| anyhow::anyhow!("table parameter required for indexes introspection"))?;
            let sql = dialect.list_indexes();
            let rows = sqlx::query(sql)
                .bind(schema)
                .bind(table)
                .fetch_all(&pool)
                .await?;
            rows.iter()
                .map(|row| {
                    json!({
                        "name": row.get::<String, _>("indexname"),
                        "definition": row.get::<String, _>("indexdef"),
                    })
                })
                .collect()
        }
    };

    pool.close().await;

    Ok(json!({
        "type": "introspect",
        "introspect_type": params.introspect_type.as_str(),
        "items": items,
        "schema": params.schema,
        "table": params.table,
        "dialect": "postgres",
    }))
}

// ---------------------------------------------------------------------------
// MySQL
// ---------------------------------------------------------------------------

async fn introspect_mysql(params: &IntrospectParams) -> Result<Value> {
    use sqlx::mysql::MySqlPoolOptions;
    use sqlx::Row;

    let pool = MySqlPoolOptions::new()
        .max_connections(2)
        .connect(&params.connection_url)
        .await?;

    let dialect = MysqlDialect;
    use crate::sql_dialect::Dialect;

    // MySQL SHOW commands return VARBINARY columns that sqlx cannot decode as String.
    // These helpers read raw bytes and convert to UTF-8 strings.
    fn col(row: &sqlx::mysql::MySqlRow, name: &str) -> String {
        let bytes: Vec<u8> = row.get(name);
        String::from_utf8_lossy(&bytes).into_owned()
    }
    fn col_opt(row: &sqlx::mysql::MySqlRow, name: &str) -> Option<String> {
        let bytes: Option<Vec<u8>> = row.get(name);
        bytes.map(|b| String::from_utf8_lossy(&b).into_owned())
    }
    fn col_idx(row: &sqlx::mysql::MySqlRow, idx: usize) -> String {
        let bytes: Vec<u8> = row.get(idx);
        String::from_utf8_lossy(&bytes).into_owned()
    }

    let items: Vec<Value> = match params.introspect_type {
        IntrospectType::Databases => {
            let sql = dialect.list_databases();
            let rows = sqlx::query(sql).fetch_all(&pool).await?;
            rows.iter()
                .map(|row| json!({ "name": col_idx(row, 0) }))
                .collect()
        }
        IntrospectType::Schemas => {
            // MySQL doesn't support schemas
            Vec::new()
        }
        IntrospectType::Tables => {
            let sql = dialect.list_tables();
            let rows = sqlx::query(sql).fetch_all(&pool).await?;
            rows.iter()
                .map(|row| {
                    json!({
                        "name": col_idx(row, 0),
                        "type": "BASE TABLE",
                    })
                })
                .collect()
        }
        IntrospectType::Columns => {
            let table = params
                .table
                .as_deref()
                .ok_or_else(|| anyhow::anyhow!("table parameter required for columns introspection"))?;
            // SQL template is "SHOW FULL COLUMNS FROM `{}`" — {} is already
            // inside backticks, so substitute the raw name.
            let sql = dialect.list_columns().replace("{}", table);
            let rows = sqlx::query(&sql).fetch_all(&pool).await?;
            rows.iter()
                .map(|row| {
                    json!({
                        "name": col(row, "Field"),
                        "type": col(row, "Type"),
                        "nullable": col(row, "Null") == "YES",
                        "default": col_opt(row, "Default"),
                        "key": col(row, "Key"),
                        "extra": col(row, "Extra"),
                    })
                })
                .collect()
        }
        IntrospectType::Indexes => {
            let table = params
                .table
                .as_deref()
                .ok_or_else(|| anyhow::anyhow!("table parameter required for indexes introspection"))?;
            // SQL template is "SHOW INDEX FROM `{}`" — same as above.
            let sql = dialect.list_indexes().replace("{}", table);
            let rows = sqlx::query(&sql).fetch_all(&pool).await?;
            // Group by index name (SHOW INDEX returns one row per column per index)
            let mut index_map: std::collections::BTreeMap<String, Vec<String>> =
                std::collections::BTreeMap::new();
            for row in &rows {
                let key_name = col(row, "Key_name");
                let column_name = col(row, "Column_name");
                index_map.entry(key_name).or_default().push(column_name);
            }
            index_map
                .into_iter()
                .map(|(name, columns)| {
                    json!({
                        "name": name,
                        "columns": columns,
                        "definition": format!("INDEX {} ({})", name, columns.join(", ")),
                    })
                })
                .collect()
        }
    };

    pool.close().await;

    Ok(json!({
        "type": "introspect",
        "introspect_type": params.introspect_type.as_str(),
        "items": items,
        "schema": params.schema,
        "table": params.table,
        "dialect": "mysql",
    }))
}

// ---------------------------------------------------------------------------
// SQLite
// ---------------------------------------------------------------------------

async fn introspect_sqlite(params: &IntrospectParams) -> Result<Value> {
    use sqlx::sqlite::SqlitePoolOptions;
    use sqlx::Row;

    let conn_str = normalize_sqlite_connection(&params.connection_url)?;

    let pool = SqlitePoolOptions::new()
        .max_connections(2)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(&conn_str)
        .await?;

    let dialect = SqliteDialect;
    use crate::sql_dialect::Dialect;

    let items: Vec<Value> = match params.introspect_type {
        IntrospectType::Databases => {
            let sql = dialect.list_databases();
            let rows = sqlx::query(sql).fetch_all(&pool).await?;
            rows.iter()
                .map(|row| {
                    json!({
                        "name": row.get::<String, _>("name"),
                        "file": row.get::<Option<String>, _>("file"),
                    })
                })
                .collect()
        }
        IntrospectType::Schemas => {
            // SQLite doesn't have schemas
            Vec::new()
        }
        IntrospectType::Tables => {
            let sql = dialect.list_tables();
            let rows = sqlx::query(sql).fetch_all(&pool).await?;
            rows.iter()
                .map(|row| {
                    json!({
                        "name": row.get::<String, _>("name"),
                        "type": "BASE TABLE",
                    })
                })
                .collect()
        }
        IntrospectType::Columns => {
            let table = params
                .table
                .as_deref()
                .ok_or_else(|| anyhow::anyhow!("table parameter required for columns introspection"))?;
            let quoted = dialect.quote_identifier(table);
            let sql = dialect.list_columns().replace("{}", &quoted);
            let rows = sqlx::query(&sql).fetch_all(&pool).await?;
            rows.iter()
                .map(|row| {
                    json!({
                        "name": row.get::<String, _>("name"),
                        "type": row.get::<String, _>("type"),
                        "nullable": row.get::<i64, _>("notnull") == 0,
                        "default": row.get::<Option<String>, _>("dflt_value"),
                        "pk": row.get::<i64, _>("pk") > 0,
                    })
                })
                .collect()
        }
        IntrospectType::Indexes => {
            let table = params
                .table
                .as_deref()
                .ok_or_else(|| anyhow::anyhow!("table parameter required for indexes introspection"))?;
            let quoted = dialect.quote_identifier(table);
            let sql = dialect.list_indexes().replace("{}", &quoted);
            let rows = sqlx::query(&sql).fetch_all(&pool).await?;
            rows.iter()
                .map(|row| {
                    json!({
                        "name": row.get::<String, _>("name"),
                        "unique": row.get::<i64, _>("unique") > 0,
                    })
                })
                .collect()
        }
    };

    pool.close().await;

    Ok(json!({
        "type": "introspect",
        "introspect_type": params.introspect_type.as_str(),
        "items": items,
        "table": params.table,
        "dialect": "sqlite",
    }))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_introspect_type_from_str() {
        assert_eq!(
            IntrospectType::from_str("databases").unwrap(),
            IntrospectType::Databases
        );
        assert_eq!(
            IntrospectType::from_str("SCHEMAS").unwrap(),
            IntrospectType::Schemas
        );
        assert_eq!(
            IntrospectType::from_str("Tables").unwrap(),
            IntrospectType::Tables
        );
        assert_eq!(
            IntrospectType::from_str("columns").unwrap(),
            IntrospectType::Columns
        );
        assert_eq!(
            IntrospectType::from_str("indexes").unwrap(),
            IntrospectType::Indexes
        );
        assert!(IntrospectType::from_str("invalid").is_err());
        assert!(IntrospectType::from_str("").is_err());
    }

    #[test]
    fn test_introspect_type_as_str() {
        assert_eq!(IntrospectType::Databases.as_str(), "databases");
        assert_eq!(IntrospectType::Schemas.as_str(), "schemas");
        assert_eq!(IntrospectType::Tables.as_str(), "tables");
        assert_eq!(IntrospectType::Columns.as_str(), "columns");
        assert_eq!(IntrospectType::Indexes.as_str(), "indexes");
    }

    #[tokio::test]
    async fn test_introspect_sqlite_tables() {
        let db_path = "/tmp/poste_test_introspect_tables.db";
        // Clean up any prior test DB
        let _ = std::fs::remove_file(db_path);

        std::process::Command::new("sqlite3")
            .args([
                db_path,
                "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT);",
            ])
            .output()
            .expect("sqlite3 should be available");

        std::process::Command::new("sqlite3")
            .args([
                db_path,
                "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER, title TEXT);",
            ])
            .output()
            .expect("sqlite3 should be available");

        let params = IntrospectParams {
            connection_url: format!("sqlite:{}", db_path),
            dialect_name: "sqlite".to_string(),
            introspect_type: IntrospectType::Tables,
            schema: None,
            table: None,
        };

        let result = introspect(&params).await.unwrap();
        assert_eq!(result["type"], "introspect");
        assert_eq!(result["introspect_type"], "tables");
        assert_eq!(result["dialect"], "sqlite");

        let items = result["items"].as_array().unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["name"], "posts");
        assert_eq!(items[1]["name"], "users");

        let _ = std::fs::remove_file(db_path);
    }

    #[tokio::test]
    async fn test_introspect_sqlite_columns() {
        let db_path = "/tmp/poste_test_introspect_cols.db";
        let _ = std::fs::remove_file(db_path);

        std::process::Command::new("sqlite3")
            .args([
                db_path,
                "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT DEFAULT 'x');",
            ])
            .output()
            .expect("sqlite3 should be available");

        let params = IntrospectParams {
            connection_url: format!("sqlite:{}", db_path),
            dialect_name: "sqlite".to_string(),
            introspect_type: IntrospectType::Columns,
            schema: None,
            table: Some("t".to_string()),
        };

        let result = introspect(&params).await.unwrap();
        assert_eq!(result["introspect_type"], "columns");

        let items = result["items"].as_array().unwrap();
        assert_eq!(items.len(), 3);
        assert_eq!(items[0]["name"], "id");
        assert_eq!(items[0]["pk"], true);
        assert_eq!(items[1]["name"], "name");
        assert_eq!(items[1]["nullable"], false);
        assert_eq!(items[2]["name"], "email");
        assert_eq!(items[2]["default"], "'x'");

        let _ = std::fs::remove_file(db_path);
    }

    #[tokio::test]
    async fn test_introspect_sqlite_indexes() {
        let db_path = "/tmp/poste_test_introspect_idx.db";
        let _ = std::fs::remove_file(db_path);

        std::process::Command::new("sqlite3")
            .args([
                db_path,
                "CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); CREATE INDEX idx_name ON t(name);",
            ])
            .output()
            .expect("sqlite3 should be available");

        let params = IntrospectParams {
            connection_url: format!("sqlite:{}", db_path),
            dialect_name: "sqlite".to_string(),
            introspect_type: IntrospectType::Indexes,
            schema: None,
            table: Some("t".to_string()),
        };

        let result = introspect(&params).await.unwrap();
        let items = result["items"].as_array().unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["name"], "idx_name");

        let _ = std::fs::remove_file(db_path);
    }

    #[tokio::test]
    async fn test_introspect_sqlite_databases() {
        let params = IntrospectParams {
            connection_url: "sqlite::memory:".to_string(),
            dialect_name: "sqlite".to_string(),
            introspect_type: IntrospectType::Databases,
            schema: None,
            table: None,
        };

        let result = introspect(&params).await.unwrap();
        let items = result["items"].as_array().unwrap();
        assert!(!items.is_empty());
        assert_eq!(items[0]["name"], "main");
    }

    #[tokio::test]
    async fn test_introspect_sqlite_schemas_empty() {
        let params = IntrospectParams {
            connection_url: "sqlite::memory:".to_string(),
            dialect_name: "sqlite".to_string(),
            introspect_type: IntrospectType::Schemas,
            schema: None,
            table: None,
        };

        let result = introspect(&params).await.unwrap();
        let items = result["items"].as_array().unwrap();
        assert!(items.is_empty());
    }

    #[tokio::test]
    async fn test_introspect_unknown_dialect() {
        let params = IntrospectParams {
            connection_url: "fake://conn".to_string(),
            dialect_name: "oracle".to_string(),
            introspect_type: IntrospectType::Tables,
            schema: None,
            table: None,
        };

        let result = introspect(&params).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("Unknown dialect"));
    }

    #[tokio::test]
    async fn test_introspect_columns_without_table_errors() {
        let params = IntrospectParams {
            connection_url: "sqlite::memory:".to_string(),
            dialect_name: "sqlite".to_string(),
            introspect_type: IntrospectType::Columns,
            schema: None,
            table: None, // missing!
        };

        let result = introspect(&params).await;
        assert!(result.is_err());
    }
}
