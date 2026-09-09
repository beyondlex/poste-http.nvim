local cache = require("poste-http.http.cache")
local poste_select = require("poste-http.select")
local jq_mapping = require("poste-http.http.jq_mapping")

local M = {}

function M.strip_prompt_lines(content)
  local result = {}
  for _, l in ipairs(vim.split(content, "\n", { plain = true })) do
    if not l:match("^%s*<<[%a_][%w_]*") then
      table.insert(result, l)
    end
  end
  return table.concat(result, "\n")
end

function M.handle_prompt_variables(buf, cursor_line, content, file, env_name, on_complete, opts)
  opts = opts or {}
  local execute_dep = opts.execute_dep
  local resolve_req_var = opts.resolve_req_var
  local collect_requests = opts.collect_requests

  local start_line, end_line = cache.find_request_block_bounds(buf, cursor_line)
  if not start_line then
    on_complete(content)
    return
  end

  local lines = vim.split(content, "\n", { plain = true })
  local header_line = lines[start_line] or ""
  local request_name = header_line:match("^%s*###%s+(%S.*)$")
  request_name = request_name and vim.trim(request_name) or ""

  local result = {}
  local idx = 1
  local cancelled = false

  local function process_next()
    -- A cancelled prompt aborts the rest of the walk: the resolution result
    -- is discarded anyway, so later <<vars must not prompt again.
    if cancelled then
      on_complete(nil)
      return
    end
    if idx > #lines then
      on_complete(table.concat(result, "\n"))
      return
    end

    local line = lines[idx]
    local line_num = idx
    idx = idx + 1

    if line_num >= start_line and line_num <= end_line then
      local varname_sel, options_str = line:match("^%s*<<([%a_][%w_]*)%s*%[(.+)%]")

      if varname_sel and options_str then
        local ref_match = options_str:gsub("%.res%.", ".response."):match("{{(.+%.response%..+)}}")

        if ref_match and execute_dep and resolve_req_var and collect_requests then
          local ref_text, mapping = jq_mapping.parse_dynamic_mapping("{{" .. ref_match .. "}}")
          if not ref_text then ref_text = ref_match end

          local requests = collect_requests(buf)
          local req_name = ref_text:match("^([^%.]+)%.")

          if req_name then
            local dep_req = nil
            for _, req in ipairs(requests) do
              if req.name == req_name then
                dep_req = req
                break
              end
            end

            if dep_req then
              local all_lines = vim.split(content, "\n", { plain = true })
              local dep_lines = {}
              for i = dep_req.start_line, dep_req.end_line do
                table.insert(dep_lines, all_lines[i] or "")
              end
              local dep_resolved = table.concat(dep_lines, "\n")

              execute_dep(buf, file, env_name, dep_req, dep_resolved, function(response)
                if response then
                  local value = resolve_req_var(ref_text, { [req_name] = response })
                  if type(value) == "string" and mapping then
                    local ok, parsed = pcall(vim.json.decode, value)
                    if ok then value = parsed end
                  end
                  if value and type(value) == "table" then
                    if mapping then
                      local items = jq_mapping.apply_jq_mapping(value, mapping)
                      if #items > 0 then
                        local prompt = string.format("[%s] Select value for '%s'", request_name, varname_sel)
                        poste_select.select(items, prompt, function(selected)
                          if selected then
                            table.insert(result, string.format("@%s = %s", varname_sel, selected))
                          else
                            cancelled = true
                          end
                          process_next()
                        end)
                        return
                      end
                    else
                      local options = {}
                      local function flatten(item)
                        if type(item) == "table" then
                          for _, sub in ipairs(item) do flatten(sub) end
                        elseif type(item) == "string" then
                          table.insert(options, item)
                        elseif type(item) == "number" then
                          table.insert(options, tostring(item))
                        end
                      end
                      for _, item in ipairs(value) do flatten(item) end

                      if #options > 0 then
                        local prompt = string.format("[%s] Select value for '%s'", request_name, varname_sel)
                        poste_select.select(options, prompt, function(selected)
                          if selected then
                            table.insert(result, string.format("@%s = %s", varname_sel, selected))
                          else
                            cancelled = true
                          end
                          process_next()
                        end)
                        return
                      end
                    end
                  end
                end
                local options = jq_mapping.parse_structured_options(options_str:gsub("{{.+}}", ""))
                if #options > 0 then
                  local prompt = string.format("[%s] Select value for '%s'", request_name, varname_sel)
                  poste_select.select(options, prompt, function(selected)
                    if selected then
                      table.insert(result, string.format("@%s = %s", varname_sel, selected))
                    else
                      cancelled = true
                    end
                    process_next()
                  end)
                else
                  table.insert(result, line)
                  process_next()
                end
              end)
              return
            end
          end
        end

        local options = jq_mapping.parse_structured_options(options_str)

        if #options == 0 then
          table.insert(result, line)
          process_next()
          return
        end

        local prompt = string.format("[%s] Select value for '%s'", request_name, varname_sel)
        poste_select.select(options, prompt, function(selected)
          if selected then
            table.insert(result, string.format("@%s = %s", varname_sel, selected))
          else
            cancelled = true
          end
          process_next()
        end)
        return
      end

      local varname_ref, ref_var_name = line:match("^%s*<<([%a_][%w_]*)%s*{{([%a_][%w_]*)}}%s*$")
      if varname_ref and ref_var_name then
        local ref_value = nil
        for i = start_line, end_line do
          local val = lines[i]:match("^%s*@" .. ref_var_name .. "%s*=%s*(.+)$")
          if val then
            ref_value = vim.trim(val)
            break
          end
        end
        if ref_value == nil then
          for i = 1, start_line - 1 do
            local val = lines[i]:match("^%s*@" .. ref_var_name .. "%s*=%s*(.+)$")
            if val then
              ref_value = vim.trim(val)
              break
            end
          end
        end

        if ref_value then
          local options_content = ref_value:match("^%[(.+)%]$")
          if options_content then
            local options = jq_mapping.parse_structured_options(options_content)
            if #options > 0 then
              local prompt = string.format("[%s] Select value for '%s'", request_name, varname_ref)
              poste_select.select(options, prompt, function(selected)
                if selected then
                  table.insert(result, string.format("@%s = %s", varname_ref, selected))
                else
                  cancelled = true
                end
                process_next()
              end)
              return
            end
          end
          vim.schedule(function()
            local ok, value = pcall(vim.fn.input, {
              prompt = string.format("[%s] Enter value for '%s': ", request_name, varname_ref),
              default = ref_value,
            })
            if ok and value and value ~= "" then
              table.insert(result, string.format("@%s = %s", varname_ref, value))
            else
              cancelled = true
            end
            process_next()
          end)
          return
        end
      end

      local varname = line:match("^%s*<<([%a_][%w_]*)")

      if varname then
        vim.schedule(function()
          local ok, value = pcall(vim.fn.input, {
            prompt = string.format("[%s] Enter value for '%s': ", request_name, varname),
            default = "",
          })

          if ok and value and value ~= "" then
            table.insert(result, string.format("@%s = %s", varname, value))
          else
            cancelled = true
          end
          process_next()
        end)
        return
      end
    end

    table.insert(result, line)
    process_next()
  end

  process_next()
end

return M