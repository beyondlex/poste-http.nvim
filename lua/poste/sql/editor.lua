--- Dataset cell editor — orchestration module.
--- Re-exports from sub-modules for backward compatibility.
--- Sub-modules: cell.lua (value ops), column.lua (PK introspection), nav.lua (interactive editing).

local cell = require("poste.sql.editor.cell")
local column = require("poste.sql.editor.column")
local nav = require("poste.sql.editor.nav")

local M = {}

-- Re-export cell functions -------------------------------------------------
M.is_numeric_type          = cell.is_numeric_type
M.is_integer_type          = cell.is_integer_type
M.is_boolean_type          = cell.is_boolean_type
M.is_date_type             = cell.is_date_type
M.is_uuid_type             = cell.is_uuid_type
M.is_text_type             = cell.is_text_type
M.is_json_column           = cell.is_json_column
M.is_boolean_column        = cell.is_boolean_column
M.is_datetime_column       = cell.is_datetime_column
M.is_enum_column           = cell.is_enum_column
M.is_editable_field        = cell.is_editable_field
M.parse_value              = cell.parse_value
M.validate_value           = cell.validate_value
M.create_edit_state        = cell.create_edit_state
M.track_cell_edit          = cell.track_cell_edit
M.track_row_delete         = cell.track_row_delete
M.track_row_add            = cell.track_row_add
M.has_pending_changes      = cell.has_pending_changes
M.get_edit_summary         = cell.get_edit_summary
M.count_pending_changes    = cell.count_pending_changes
M.pending_changes_text     = cell.pending_changes_text
M.reset_edit_state         = cell.reset_edit_state
M.clear_cell_error         = cell.clear_cell_error
M.set_cell_error           = cell.set_cell_error
M.format_json_input        = cell.format_json_input
M.parse_json_input         = cell.parse_json_input

-- Re-export column functions ------------------------------------------------
M.has_join                 = column.has_join
M.ensure_primary_key       = column.ensure_primary_key
M.clear_pk_cache           = column.clear_pk_cache

-- Re-export nav functions ---------------------------------------------------
M.is_data_row              = nav.is_data_row
M.detect_cell_type         = nav.detect_cell_type
M.edit_cell                = nav.edit_cell
M.delete_row               = nav.delete_row
M.insert_row               = nav.insert_row
M.rollback_edits           = nav.rollback_edits

return M
