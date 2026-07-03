return {
  -- Each fixture:
  --   name:        test case description
  --   lines:       buffer lines, █ marks cursor (replaced with "" in buffer)
  --   env_json:    optional { path = "...", content = { dev = { ... }, ... } }
  --                creates env.json at path, sets buffer name to path + "/test.http"
  --   expect:      list of labels that MUST be in completion items
  --   expect_not:  list of labels that MUST NOT be in completion items

  -- ── File-level area ──
  { name = "empty line returns HTTP methods", lines = { "█" }, expect = { "GET", "POST", "PUT" } },
  { name = "whitespace-only line returns HTTP methods", lines = { "  █" }, expect = { "GET", "POST" } },
  { name = "single word returns methods + headers", lines = { "G█" }, expect = { "GET", "Content-Type" } },
  { name = "partial header name returns methods + headers", lines = { "Con█" }, expect = { "Content-Type", "CONNECT" } },
  { name = "comment line returns no completion", lines = { "# this is a comment█" }, expect_not = { "GET" } },
  { name = "--- comment returns no completion", lines = { "--- comment█" }, expect_not = { "GET" } },
  { name = "@var definition returns no completion", lines = { "@base_url = http://example.com█" }, expect_not = { "GET" } },
  { name = "URL with :// returns no completion", lines = { "GET http://example.com█" }, expect_not = { "GET" } },
  { name = "after complete method + space returns no completion", lines = { "GET █" }, expect_not = { "GET" } },

  -- ── Import directives ──
  { name = "import triggers path completion", lines = { "import █" }, expect = { "./", "../" } },
  { name = "import with partial path returns nothing", lines = { "import ./helper█" }, expect_not = { "as" } },
  { name = "import with alias partial returns 'as'", lines = { "import ./helper.http a█" }, expect = { "as" } },

  -- ── Run directive ──
  { name = "run triggers target completion", lines = { "### Test", "run █" }, expect = { "#", "./" } },

  -- ── Request block area ──
  { name = "empty line after ### returns HTTP methods", lines = { "### Get Users", "█" }, expect = { "GET", "POST" } },
  { name = "single word after ### returns methods + headers", lines = { "### Get Users", "C█" }, expect = { "Content-Type", "CONNECT" } },
  { name = "### header line returns no completion", lines = { "### Get Users█" }, expect_not = { "GET" } },

  -- ── Header values ──
  { name = "Content-Type: returns MIME types", lines = { "### Test", "Content-Type: █" }, expect = { "application/json", "text/html" } },
  { name = "Accept: returns MIME types", lines = { "### Test", "Accept: █" }, expect = { "application/json", "text/html" } },
  { name = "Accept-Encoding: returns encodings", lines = { "### Test", "Accept-Encoding: █" }, expect = { "gzip", "deflate" } },
  { name = "unknown header returns empty", lines = { "### Test", "X-Foo: █" }, expect_not = { "application/json" } },

  -- ── Variable completion ({{ }}) ──
  { name = "{{ returns magic + file vars", lines = { "### Test", "{{█" }, expect = { "$timestamp", "$uuid" } },
  { name = "{{ after GET returns variables", lines = { "### Test", "GET {{█" }, expect = { "$timestamp", "$uuid" } },
  { name = "{{$ returns only magic vars", lines = { "### Test", "{{$█" }, expect = { "$timestamp", "$uuid", "$date", "$randomInt" }, expect_not = { "base_url" } },
  -- item_builder returns all magic vars when is_magic=true (prefix filtering is done client-side by blink.cmp)
  { name = "{{$ti returns all magic vars", lines = { "### Test", "{{$ti█" }, expect = { "$timestamp", "$uuid", "$date", "$randomInt" } },
  { name = "closed }} returns no completion", lines = { "### Test", "{{host}}█" }, expect_not = { "$timestamp" } },
  { name = "second {{ after closed }} returns vars", lines = { "### Test", "{{host}} {{█" }, expect = { "$timestamp", "$uuid" } },

  -- ── Variable with file-level @var ──
  { name = "{{ includes file-level @var", lines = { "@base_url = http://example.com", "### Test", "{{█" }, expect = { "base_url", "$timestamp" } },
  { name = "{{ includes block-level @var", lines = { "### Test", "@limit = 20", "{{█" }, expect = { "limit", "$timestamp" } },

  -- ── Variable with env.json ──
  {
    name = "{{ includes env vars from env.json",
    lines = { "### Test", "{{█" },
    env_json = {
      path = "/tmp/poste_test_env",
      content = { dev = { redis_host = "127.0.0.1", redis_port = "6379" } },
    },
    expect = { "$timestamp", "redis_host", "redis_port" },
  },

  -- ── @prompt line ──
  -- @prompt lines allow {{ completion (context_detector passes through), returns magic vars
  { name = "# @prompt with {{ returns magic vars", lines = { "### Test", "# @prompt fruit [{{█" }, expect = { "$timestamp", "$uuid" } },

  -- ── Directives as completion items ──
  { name = "empty line returns directives too", lines = { "█" }, expect = { "import", "run" } },

  -- ── Run with import index ──
  {
    name = "run # with imports returns alias name",
    lines = { "import ./helper_auth.http as auth", "### Test", "run #█" },
    import_fixtures = {
      { path = "helper_auth.http", lines = { "### Login", "POST /login", "", '{"user":"admin"}' } },
    },
    -- When import has alias, run # shows the alias, not individual requests
    expect = { "#auth" },
  },

  -- ── Run with alias ──
  {
    name = "run #alias. returns requests from that alias",
    lines = { "import ./helper_auth.http as auth", "### Test", "run #auth.█" },
    import_fixtures = {
      { path = "helper_auth.http", lines = { "### Login", "POST /login", "", '{"user":"admin"}' } },
    },
    expect = { "Login" },
  },
}
