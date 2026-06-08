/// SQL function names for completion.
pub fn known_functions() -> &'static [&'static str] {
    &[
        // String
        "CONCAT", "CONCAT_WS", "FORMAT", "INSTR", "LOCATE", "POSITION",
        "LEFT", "RIGHT", "SUBSTRING", "SUBSTR", "MID", "SUBSTRING_INDEX",
        "LENGTH", "CHAR_LENGTH", "CHARACTER_LENGTH", "OCTET_LENGTH", "BIT_LENGTH",
        "LOWER", "LCASE", "UPPER", "UCASE", "TRIM", "LTRIM", "RTRIM",
        "REPLACE", "REGEXP_REPLACE", "REGEXP_LIKE", "REGEXP_SUBSTR", "REGEXP_INSTR",
        "REPEAT", "REVERSE", "LPAD", "RPAD", "SPACE",
        "FIELD", "FIND_IN_SET", "ELT", "SOUNDEX",
        "ASCII", "ORD", "CHAR", "UNICODE", "UNHEX", "HEX",
        "QUOTE", "STRCMP",

        // Numeric / Math
        "ABS", "CEIL", "CEILING", "FLOOR", "ROUND", "TRUNCATE", "TRUNC",
        "RAND", "RANDOM", "POWER", "POW", "SQRT", "EXP", "LN", "LOG", "LOG2", "LOG10",
        "MOD", "SIGN", "PI", "DIV", "CRC32",
        "SIN", "COS", "TAN", "ASIN", "ACOS", "ATAN", "ATAN2",
        "RADIANS", "DEGREES",
        "GREATEST", "LEAST",

        // Aggregate / Window
        "COUNT", "SUM", "AVG", "MIN", "MAX", "GROUP_CONCAT", "STRING_AGG", "ARRAY_AGG",
        "STD", "STDDEV", "STDDEV_POP", "STDDEV_SAMP",
        "VAR_POP", "VAR_SAMP", "VARIANCE",
        "BIT_AND", "BIT_OR", "BIT_XOR",
        "ROW_NUMBER", "RANK", "DENSE_RANK", "NTILE", "LAG", "LEAD",
        "FIRST_VALUE", "LAST_VALUE", "NTH_VALUE",
        "CUME_DIST", "PERCENT_RANK", "PERCENTILE_CONT", "PERCENTILE_DISC",

        // Date / Time
        "NOW", "SYSDATE", "LOCALTIME", "LOCALTIMESTAMP",
        "UTC_DATE", "UTC_TIME", "UTC_TIMESTAMP",
        "CURDATE", "CURTIME",
        "YEAR", "MONTH", "DAY", "DAYOFMONTH", "DAYOFWEEK", "DAYOFYEAR",
        "WEEK", "WEEKDAY", "WEEKOFYEAR",
        "HOUR", "MINUTE", "SECOND", "MICROSECOND",
        "QUARTER", "LAST_DAY",
        "DATE_FORMAT", "TIME_FORMAT",
        "FROM_UNIXTIME", "UNIX_TIMESTAMP",
        "STR_TO_DATE", "TO_DAYS", "FROM_DAYS",
        "DATE_ADD", "DATE_SUB", "ADDDATE", "SUBDATE",
        "ADDTIME", "SUBTIME", "TIMEDIFF", "TIMESTAMPDIFF", "TIMESTAMPADD",
        "DATEDIFF",
        "EXTRACT", "DATE_PART",
        "MAKEDATE", "MAKETIME", "MAKE_DATE", "MAKE_TIME", "MAKE_TIMESTAMP",
        "CONVERT_TZ",
        "DATE_TRUNC", "TIME_TRUNC",
        "AGE", "ISFINITE", "JUSTIFY_DAYS", "JUSTIFY_HOURS", "JUSTIFY_INTERVAL",
        "CLOCK_TIMESTAMP", "STATEMENT_TIMESTAMP", "TRANSACTION_TIMESTAMP",

        // JSON
        "JSON_EXTRACT", "JSON_UNQUOTE", "JSON_KEYS", "JSON_CONTAINS",
        "JSON_CONTAINS_PATH", "JSON_SET", "JSON_INSERT", "JSON_REPLACE",
        "JSON_REMOVE", "JSON_ARRAY", "JSON_OBJECT", "JSON_ARRAY_APPEND",
        "JSON_MERGE", "JSON_MERGE_PATCH",
        "JSON_TYPE", "JSON_VALID", "JSON_DEPTH", "JSON_LENGTH",
        "JSON_QUOTE", "JSON_TABLE", "JSON_VALUE",
        "JSON_AGG", "JSON_OBJECT_AGG",
        "JSONB_BUILD_OBJECT", "JSONB_AGG", "JSONB_PRETTY", "JSONB_EXTRACT_PATH",
        "TO_JSON", "ROW_TO_JSON",

        // Conditional
        "COALESCE", "NULLIF", "IFNULL", "IF",

        // Type conversion
        "CAST", "CONVERT", "TRY_CAST", "TRY_CONVERT",
        "TO_CHAR", "TO_NUMBER", "TO_TIMESTAMP",

        // Security / Hash
        "MD5", "SHA1", "SHA2", "AES_ENCRYPT", "AES_DECRYPT",
        "RANDOM_BYTES", "UUID", "UUID_SHORT",

        // System / Info
        "VERSION", "DATABASE", "SCHEMA", "USER",
        "SESSION_USER", "SYSTEM_USER", "CONNECTION_ID",
        "ROW_COUNT", "FOUND_ROWS", "LAST_INSERT_ID",
        "CHARSET", "COLLATION", "CURRENT_SCHEMA",
        "CURRENT_SETTING", "SET_CONFIG",

        // Full-Text Search
        "MATCH", "AGAINST",

        // Postgres extras
        "UNNEST", "GENERATE_SERIES", "ARRAY", "ROW", "SETSEED",

        // MySQL extras
        "ANY_VALUE", "BENCHMARK",
        "GET_LOCK", "RELEASE_LOCK", "RELEASE_ALL_LOCKS",
        "IS_FREE_LOCK", "IS_USED_LOCK",
        "SLEEP", "VALUES",

        // SQLite extras
        "TOTAL", "TYPEOF", "LIKELY", "UNLIKELY", "LIKELIHOOD",
        "CHANGES", "TOTAL_CHANGES",
        "SQLITE_VERSION", "SQLITE_SOURCE_ID", "ZEROBLOB",
    ]
}
