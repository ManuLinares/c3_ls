module lsp::analysis;

import analyzer::core;
import analyzer::cursor;
import lsp::core;
import lsp;

import std::collections::list;
<*
 Precomputes line starting byte offsets in a single linear pass for O(1) lookups.
*>
fn sz[] build_line_offsets(Allocator allocator, String content)
{
	List{sz} offsets;
	offsets.init(allocator);
	offsets.push(0);  // Line 0 starts at index 0
	for (sz i = 0; i < content.len; i++)
	{
		if (content[i] == '\n')
		{
			offsets.push(i + 1);
		}
	}

	return offsets.array_view();
}

<*
 Converts line and character coordinates into a zero-indexed byte offset in O(1).
*>
fn sz offset_from_line_table(sz[] line_offsets, String content, uint target_line, uint target_char)
{
	if (target_line >= line_offsets.len) return content.len;
	sz off = line_offsets[target_line] + (sz)target_char;
	if (off > content.len) return content.len;
	return off;
}

<*
 Converts line and character coordinates into a zero-indexed byte offset in a content buffer.
*>
fn sz compute_byte_offset(String content, uint target_line, uint target_char)
{
	sz target_col = (sz)target_char;

	if (target_line == 0)
	{
		if (target_col > content.len) return content.len;
		return target_col;
	}

	uint current_line = 0;
	sz i = 0;

	while (i < content.len && current_line < target_line)
	{
		if (try next_nl = content[i..].index_of_char('\n'))
		{
			i += next_nl + 1;
			current_line++;
		}
		else
		{
			return content.len;
		}
	}

	if (current_line == target_line)
	{
		sz final_pos = i + target_col;
		if (final_pos > content.len) return content.len;
		return final_pos;
	}

	return content.len;
}

<*
 Extracts a token prefix preceding a byte offset.
*>
fn String extract_prefix(String text, sz byte_offset)
{
	if (byte_offset == 0 || byte_offset > text.len) return "";

	sz start_idx = byte_offset;
	while (start_idx > 0)
	{
		char c = text[start_idx - 1];
		if (c.is_alnum() || c == '_')
		{
			start_idx--;
		}
		else
		{
			switch (c)
			{
				case '@':
				case '#':
				case '$':
					start_idx--;
					break;
				default:
					break;
			}
			break;
		}
	}

	if (start_idx >= byte_offset) return "";
	return text[start_idx..byte_offset - 1];
}

<*
 Retrieves the canonical identifier text for any AST node with robust fallbacks.
*>
fn String get_node_symbol_name(Node* node)
{
	if (!node) return "";
	String symbol_name = cursor::spelling(node, tmem);
	switch (true)
	{
		case symbol_name.len == 0 && node.kind == IDENT_EXPR:
			{
				IdentExpr* ident_expr = node.as(IdentExpr);
				return ident_expr.ident ? ident_expr.ident.text : "";
			}
		case symbol_name.len == 0 && node.kind == TYPE_EXPR:
			{
				return cursor::raw_type_identifier(node) ?? "";
			}
		default:
			return symbol_name;
	}
}

fn CompletionItemKind completion_kind_from_node(Node* node)
{
	if (!node) return TEXT;
	switch (node.kind)
	{
		case MODULE_DECL:    return MODULE;
		case FN_DECL:        return FUNCTION;
		case ENUM_DECL:      return ENUM;
		case INTERFACE_DECL: return INTERFACE;
		case STRUCT_DECL:    return STRUCT;
		case VAR_DECL:
			{
				VarDecl* var_decl = node.as(VarDecl);
				if (var_decl.var_flags.is_const) return CONSTANT;
				return var_decl.var_kind == VAR_FIELD ? FIELD : VARIABLE;
			}
		default:
			return TEXT;
	}
}

fn MarkupContent md(String md_text)
{
	return {
		.value = md_text,
		.kind = MARKDOWN
	};
}

fn Module* find_module_by_identifier(LspWorkspace* ws, String current_module_name, String identifier)
{
	if (!ws.ctx) return null;

	String scoped_path = "";
	if (current_module_name.len > 0)
	{
		scoped_path = string::tformat("%s::%s", current_module_name, identifier);
	}
	String suffix_path = string::tformat("::%s", identifier);

	ws.ctx.modules.@each(; mod_name, mod)
	{
		if (mod_name == identifier) return mod;
		if (scoped_path.len > 0 && mod_name == scoped_path) return mod;
		if (mod_name.ends_with(suffix_path)) return mod;
	};

	return null;
}

fn void inject_type_properties(List{CompletionItem}* items, NodeKind type_kind)
{
	items.push(
	{
		.label = "alignment", .kind = PROPERTY, .detail = "sz", .documentation = md("Alignment of the type in bytes."), .data = "property"
	}
	);
	items.push(
	{
		.label = "kind", .kind = PROPERTY, .detail = "TypeKind", .documentation = md("The category / TypeKind of the type (e.g. POINTER, STRUCT, SIGNED_INT)."), .data = "property"
	}
	);
	items.push(
	{
		.label = "name", .kind = PROPERTY, .detail = "String", .documentation = md("The short unqualified name of the type as a string."), .data = "property"
	}
	);
	items.push(
	{
		.label = "qname", .kind = PROPERTY, .detail = "String", .documentation = md("The fully qualified path name of the type as a string."), .data = "property"
	}
	);
	items.push(
	{
		.label = "size", .kind = PROPERTY, .detail = "sz", .documentation = md("Storage size of the type in bytes."), .data = "property"
	}
	);
	items.push(
	{
		.label = "typeid", .kind = PROPERTY, .detail = "typeid", .documentation = md("The unique runtime / compile-time type identifier."), .data = "property"
	}
	);
	items.push(
	{
		.label = "methods", .kind = PROPERTY, .detail = "any[]", .documentation = md("List of methods implemented for this type."), .data = "property"
	}
	);

	switch (type_kind)
	{
		case STRUCT_DECL:
			items.push(
			{
				.label = "members", .kind = PROPERTY, .detail = "any[]", .documentation = md("Array of fields/members in the struct or union."), .data = "property"
			}
			);
			items.push(
			{
				.label = "get_tag", .kind = METHOD, .detail = "fn any(String)", .documentation = md("Retrieve the value of a compile-time @tag on the type."), .data = "property"
			}
			);
			items.push(
			{
				.label = "has_tag", .kind = METHOD, .detail = "fn bool(String)", .documentation = md("Check if a compile-time @tag exists on the type."), .data = "property"
			}
			);
			items.push(
			{
				.label = "is_substruct", .kind = PROPERTY, .detail = "bool", .documentation = md("True if the struct has an inline member."), .data = "property"
			}
			);
			items.push(
			{
				.label = "parent", .kind = PROPERTY, .detail = "typeid", .documentation = md("The typeid of the inline member if present."), .data = "property"
			}
			);
		case ENUM_DECL:
			items.push(
			{
				.label = "values", .kind = PROPERTY, .detail = "any[]", .documentation = md("List containing all variants of the enum."), .data = "property"
			}
			);
			items.push(
			{
				.label = "len", .kind = PROPERTY, .detail = "sz", .documentation = md("Number of elements in the enum or array."), .data = "property"
			}
			);
			items.push(
			{
				.label = "members", .kind = PROPERTY, .detail = "any[]", .documentation = md("List of member references in the enum."), .data = "property"
			}
			);
			items.push(
			{
				.label = "from_ordinal", .kind = METHOD, .detail = "fn type(sz)", .documentation = md("Converts an integer ordinal to the corresponding enum variant."), .data = "property"
			}
			);
			items.push(
			{
				.label = "lookup_field", .kind = METHOD, .detail = "fn any(String)", .documentation = md("Lookup an enum variant by associated field value."), .data = "property"
			}
			);
		case FN_DECL:
			items.push(
			{
				.label = "params", .kind = PROPERTY, .detail = "any[]", .documentation = md("Function pointer parameter types."), .data = "property"
			}
			);
			items.push(
			{
				.label = "returns", .kind = PROPERTY, .detail = "typeid", .documentation = md("Function pointer return type."), .data = "property"
			}
			);
		default:
			break;
	}
}

fn bool is_inside_comment(String content, sz offset)
{
	if (offset > content.len) return false;

	sz i = 0;
	while (i < content.len && i <= offset)
	{
		// 1. Line comment // ... \n
		if (i + 1 < content.len && content[i] == '/' && content[i + 1] == '/')
		{
			sz comment_start = i;
			while (i < content.len && content[i] != '\n')
			{
				i++;
			}
			if (offset >= comment_start && offset <= i) return true;
			continue;
		}

		// 2. Block comment /* ... */ (supports C3 nesting)
		if (i + 1 < content.len && content[i] == '/' && content[i + 1] == '*')
		{
			sz comment_start = i;
			i += 2;
			int depth = 1;
			while (i + 1 < content.len && depth > 0)
			{
				if (content[i] == '/' && content[i + 1] == '*')
				{
					depth++;
					i += 2;
					continue;
				}
				if (content[i] == '*' && content[i + 1] == '/')
				{
					depth--;
					i += 2;
					continue;
				}
				i++;
			}
			if (offset >= comment_start && (depth > 0 || offset <= i)) return true;
			continue;
		}

		// 3. Doc contract <* ... *>
		if (i + 1 < content.len && content[i] == '<' && content[i + 1] == '*')
		{
			sz comment_start = i;
			i += 2;
			int depth = 1;
			while (i + 1 < content.len && depth > 0)
			{
				if (content[i] == '<' && content[i + 1] == '*')
				{
					depth++;
					i += 2;
					continue;
				}
				if (content[i] == '*' && content[i + 1] == '>')
				{
					depth--;
					i += 2;
					continue;
				}
				i++;
			}
			if (offset >= comment_start && (depth > 0 || offset <= i)) return true;
			continue;
		}

		// 4. String literal " ... "
		if (content[i] == '"')
		{
			i++;
			while (i < content.len && content[i] != '"')
			{
				if (content[i] == '\\' && i + 1 < content.len) i++;
				i++;
			}
			if (i < content.len) i++;
			continue;
		}

		// 5. Raw string literal ` ... `
		if (content[i] == '`')
		{
			i++;
			while (i < content.len && content[i] != '`')
			{
				i++;
			}
			if (i < content.len) i++;
			continue;
		}

		i++;
	}

	return false;
}