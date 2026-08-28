module lsp::analysis;

import analyzer::core;
import analyzer::cursor;
import lsp::core;
import lsp;

import std::collections::list;

struct ReflProp @local
{
	String name;
	String detail;
	String doc;
}

<*
 Precomputes line starting byte offsets in a single linear pass for O(1) lookups.
*>
fn sz[] build_line_offsets(Allocator allocator, String content)
{
	List{sz} offsets;
	offsets.init(allocator);
	offsets.push(0);
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

macro void @add_prop(items, String label, CompletionItemKind kind, String detail, MarkupContent doc, bool missing_colon)
{
	String ins = missing_colon ? string::tformat(":%s", label) : label;
	items.push(
	{
		.label = label,
		.kind = kind,
		.detail = detail,
		.documentation = doc,
		.insertText = ins,
		.filterText = label,
		.sortText = string::tformat("0001_%s", label),
		.data = "property"
	}
	);
}

fn void inject_type_properties(List{CompletionItem} * items, NodeKind type_kind, String type_name = "", bool missing_second_colon = false)
{
	@add_prop(items, "alignment", PROPERTY, "sz", md("Alignment of the type in bytes."), missing_second_colon);
	@add_prop(items, "kind", PROPERTY, "TypeKind", md("The category / TypeKind of the type (e.g. POINTER, STRUCT, SIGNED_INT)."), missing_second_colon);
	@add_prop(items, "name", PROPERTY, "String", md("The short unqualified name of the type as a string."), missing_second_colon);
	@add_prop(items, "qname", PROPERTY, "String", md("The fully qualified path name of the type as a string."), missing_second_colon);
	@add_prop(items, "cname", PROPERTY, "String", md("External C name of the type as a string."), missing_second_colon);
	@add_prop(items, "size", PROPERTY, "sz", md("Storage size of the type in bytes."), missing_second_colon);
	@add_prop(items, "typeid", PROPERTY, "typeid", md("The unique runtime / compile-time type identifier."), missing_second_colon);
	@add_prop(items, "methods", PROPERTY, "any[]", md("List of methods implemented for this type."), missing_second_colon);
	@add_prop(items, "has_equals", PROPERTY, "bool", md("True if the type implements '==' and '!='."), missing_second_colon);
	@add_prop(items, "is_ordered", PROPERTY, "bool", md("True if the type implements comparisons (<, <=, etc.)."), missing_second_colon);
	@add_prop(items, "inner", PROPERTY, "typeid", md("Returns a typeid to an inner / pointee / base type."), missing_second_colon);
	@add_prop(items, "generic_args", PROPERTY, "typeid[]", md("List of typeids representing the generic arguments used to instantiate this type."), missing_second_colon);
	@add_prop(items, "generic_qname", PROPERTY, "String", md("Qualified name of the generic template."), missing_second_colon);
	@add_prop(items, "is_generic", METHOD, "fn bool(any)", md("Returns true if the type was instantiated from the given template."), missing_second_colon);

	bool is_float = (type_name == "float" || type_name == "double" || type_name == "float16" || type_name == "bfloat" || type_name == "float128");
	bool is_int = (type_name == "int" || type_name == "uint" || type_name == "short" || type_name == "ushort" ||
	type_name == "long" || type_name == "ulong" || type_name == "int128" || type_name == "uint128" ||
	type_name == "char" || type_name == "ichar" || type_name == "sz" || type_name == "usz" ||
	type_name == "iptr" || type_name == "uptr");

	if (is_float || is_int || type_kind == VAR_DECL)
	{
		@add_prop(items, "max", PROPERTY, type_name.len > 0 ? type_name : "any", md("The maximum value for the type."), missing_second_colon);
		@add_prop(items, "min", PROPERTY, type_name.len > 0 ? type_name : "any", md("The minimum value for the type."), missing_second_colon);
	}

	if (is_float)
	{
		@add_prop(items, "nan", PROPERTY, type_name, md("Representation of floating point NaN."), missing_second_colon);
		@add_prop(items, "inf", PROPERTY, type_name, md("Representation of floating point Infinity."), missing_second_colon);
	}

	switch (type_kind)
	{
		case STRUCT_DECL:
			@add_prop(items, "members", PROPERTY, "any[]", md("Array of fields/members in the struct or union."), missing_second_colon);
			@add_prop(items, "get_tag", METHOD, "fn any(String)", md("Retrieve the value of a compile-time @tag on the type."), missing_second_colon);
			@add_prop(items, "has_tag", METHOD, "fn bool(String)", md("Check if a compile-time @tag exists on the type."), missing_second_colon);
			@add_prop(items, "is_substruct", PROPERTY, "bool", md("True if the struct has an inline member."), missing_second_colon);
			@add_prop(items, "parent", PROPERTY, "typeid", md("The typeid of the inline member if present."), missing_second_colon);
		case ENUM_DECL:
			@add_prop(items, "values", PROPERTY, "any[]", md("List containing all variants of the enum."), missing_second_colon);
			@add_prop(items, "len", PROPERTY, "sz", md("Number of elements in the enum or array."), missing_second_colon);
			@add_prop(items, "names", PROPERTY, "String[]", md("Array of the names of all enum variants."), missing_second_colon);
			@add_prop(items, "members", PROPERTY, "any[]", md("List of member references in the enum."), missing_second_colon);
			@add_prop(items, "from_ordinal", METHOD, "fn type(sz)", md("Converts an integer ordinal to the corresponding enum variant."), missing_second_colon);
			@add_prop(items, "lookup_field", METHOD, "fn any(String, any)", md("Lookup an enum variant by associated field value."), missing_second_colon);
		case FN_DECL:
			@add_prop(items, "params", PROPERTY, "any[]", md("Function pointer parameter types."), missing_second_colon);
			@add_prop(items, "returns", PROPERTY, "typeid", md("Function pointer return type."), missing_second_colon);
			@add_prop(items, "param_struct", PROPERTY, "typeid", md("Struct type mirroring the parameter list."), missing_second_colon);
		default:
			break;
	}
}

fn void inject_reflect_properties(List{CompletionItem} * items, String prefix = "")
{
	const ReflProp[*] PROPS = {
		{
			"alignment", "sz", "The alignment in bytes."
		}
		,
		{ "bitoffset", "sz", "The bit offset of a bitstruct member within its backing type." },
		{ "bitsize", "sz", "The size in bits of a bitstruct member." },
		{ "cname", "String", "The external linker name of a symbol." },
		{ "get_tag", "fn any(String)", "Retrieve the value of a compile-time tag." },
		{ "has_tag", "fn bool(String)", "Check if a compile-time tag exists." },
		{ "name", "String", "The unqualified name of the symbol." },
		{ "offset", "sz", "The byte offset of a member in a struct." },
		{ "param_struct", "typeid", "The parameter struct type for a function." },
		{ "qname", "String", "The fully qualified path name of the symbol." },
		{ "size", "sz", "The size of the expression in bytes." },
		{ "type", "typeid", "The typeid of the reflected expression." },
	};

	foreach (p : PROPS)
	{
		if (prefix.len == 0 || p.name.starts_with(prefix))
		{
			items.push(
			{
				.label = p.name,
				.kind = PROPERTY,
				.detail = p.detail,
				.documentation = md(p.doc),
				.insertText = p.name,
				.filterText = p.name,
				.sortText = string::tformat("0001_%s", p.name),
				.data = "property"
			}
			);
		}
	}
}

fn bool is_inside_comment(String content, sz offset)
{
	if (offset > content.len) return false;

	sz i = 0;
	while (i < content.len && i <= offset)
	{
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
