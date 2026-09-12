module lsp::bindgen;

import std;
import analyzer::core::constants;

<*
 Extracts the source file path from a Clang AST location object.
 @param loc : "Clang AST location object."
 @return    "File path string or empty if unavailable."
*>
fn String extract_file_from_loc(Object* loc) @local
{
	if (!loc)
	{
		return "";
	}

	if (try f = loc.get_string("file"))
	{
		return f;
	}

	if (try e_loc = loc.get("expansionLoc"))
	{
		if (try f = e_loc.get_string("file"))
		{
			return f;
		}
	}

	return "";
}

<*
 Extracts file path from a node's loc object.
 @param node : "Clang AST JSON object."
 @return     "File path string or empty if unavailable."
*>
fn String extract_node_file(Object* node) @local
{
	if (try loc = node.get("loc"))
	{
		String f = extract_file_from_loc(loc);
		if (f.len > 0)
		{
			return f;
		}
	}

	return "";
}

<*
 Determines if a node originated from the target header rather than system includes.
 @param node_file     : "File path where the AST node was defined."
 @param target_header : "Target header path passed in BindgenOptions."
 @return              "True if node should be included in bindings."
*>
fn bool is_target_file(String node_file, String target_header) @local
{
	if (node_file.len == 0)
	{
		return false;
	}

	if (node_file == target_header)
	{
		return true;
	}

	sz last_slash_target = 0;
	if (try idx = target_header.rindex_of_char('/'))
	{
		last_slash_target = idx + 1;
	}
	else if (try idx = target_header.rindex_of_char('\\'))
	{
		last_slash_target = idx + 1;
	}
	String base_target = target_header[last_slash_target..];

	sz last_slash_node = 0;
	if (try idx = node_file.rindex_of_char('/'))
	{
		last_slash_node = idx + 1;
	}
	else if (try idx = node_file.rindex_of_char('\\'))
	{
		last_slash_node = idx + 1;
	}
	String base_node = node_file[last_slash_node..];

	return base_node == base_target;
}

<*
 Extracts raw and desugared type information from an AST node's type object.
*>
struct RawTypeInfo
{
	String qual_type;
	String desugared_type;
	String decl_id;
}

fn RawTypeInfo extract_type_info(Object* node) @local
{
	RawTypeInfo info = {
		.qual_type = "void*",
		.desugared_type = "",
		.decl_id = ""
	};
	if (!node)
	{
		return info;
	}

	Object* type_obj = node.get("type") ?? null;
	if (!type_obj)
	{
		return info;
	}

	info.qual_type = type_obj.get_string("qualType") ?? "void*";
	info.desugared_type = type_obj.get_string("desugaredQualType") ?? "";

	if (try decl_obj = type_obj.get("decl"))
	{
		info.decl_id = decl_obj.get_string("id") ?? "";
	}
	return info;
}

<*
 Recursively finds the first descendant AST node matching target_kind in inner.
*>
fn Object* find_descendant_by_kind(Object* node, String target_kind) @local
{
	if (!node)
	{
		return null;
	}

	if (try inner_arr = node.get("inner"))
	{
		if (inner_arr.is_array())
		{
			for (sz i = 0; i < inner_arr.len(); i++)
			{
				Object* child = inner_arr.get_at(i);
				if (!child)
				{
					continue;
				}

				String k = child.get_string("kind") ?? "";
				if (k == target_kind)
				{
					return child;
				}

				Object* found = find_descendant_by_kind(child, target_kind);
				if (found)
				{
					return found;
				}
			}
		}
	}

	return null;
}

<*
 Extracts the return type from a Clang function qualType string.
 Uses backward parenthesis matching to avoid terminating on nested attributes.
 @param qual_type : "Function signature string from Clang."
 @return          "C return type string."
*>
fn String extract_function_return_type(String qual_type) @local
{
	String s = strip_clang_attributes(qual_type).trim();
	if (try last_paren = s.rindex_of_char(')'))
	{
		s = s[:last_paren + 1].trim();
	}

	if (!s.ends_with(")"))
	{
		return "void";
	}

	int depth = 0;
	for (sz i = s.len; i > 0; i--)
	{
		char c = s[i - 1];
		if (c == ')')
		{
			depth++;
		}
		else if (c == '(')
		{
			depth--;
			if (depth == 0)
			{
				String ret = s[:i - 1].trim();
				return ret.len > 0 ? ret : "void";
			}
		}
	}

	return "void";
}

<*
 Formats a C3 function signature directly from a Clang FunctionProtoType AST node.
 Tracks return and parameter types for external alias/struct synthesis.
*>
fn String format_function_proto_from_ast(
	Allocator allocator,
	Object* fpt,
	BindgenOptions options,
	HashSet{String}* target_types = null,
	HashMap{String, String}* external_typedefs = null,
	HashMap{String, Object*}* external_records = null,
	HashMap{String, Object*}* external_enums = null,
	HashSet{String}* used_external_types = null
) @local
{
	Object* inner = fpt.get("inner") ?? null;
	if (!inner || !inner.is_array() || inner.len() == 0)
	{
		return "fn void()";
	}

	RawTypeInfo ret_info = extract_type_info(inner.get_at(0));
	if (target_types && external_typedefs && used_external_types)
	{
		track_external_type_usage(ret_info.qual_type, target_types, external_typedefs, external_records, external_enums, used_external_types);
	}
	String ret_c3 = map_c_type_to_c3(allocator, ret_info.qual_type, options.type_prefix, false, ret_info.desugared_type);

	DString params_c3;
	params_c3.init(allocator);

	for (sz i = 1; i < inner.len(); i++)
	{
		Object* param_node = inner.get_at(i);
		RawTypeInfo p_info = extract_type_info(param_node);
		if (p_info.qual_type == "void")
		{
			continue;
		}

		if (target_types && external_typedefs && used_external_types)
		{
			track_external_type_usage(p_info.qual_type, target_types, external_typedefs, external_records, external_enums, used_external_types);
		}
		String p_c3 = map_c_type_to_c3(allocator, p_info.qual_type, options.type_prefix, true, p_info.desugared_type);
		if (params_c3.len() > 0)
		{
			params_c3.append(", ");
		}
		params_c3.append(p_c3);
	}

	RawTypeInfo fpt_info = extract_type_info(fpt);
	bool is_variadic = (fpt.get_bool("variadic") ?? false) ||
		fpt_info.qual_type.ends_with(", ...)") ||
		fpt_info.qual_type.ends_with("(...)");

	if (is_variadic)
	{
		if (params_c3.len() > 0)
		{
			params_c3.append(", ...");
		}
		else
		{
			params_c3.append("...");
		}
	}

	return string::format(allocator, "fn %s(%s)", ret_c3, params_c3.str_view());
}

<*
 Formats a C3 vector type directly from a Clang VectorType AST node.
*>
fn String format_vector_type_from_ast(Allocator allocator, Object* vt, BindgenOptions options) @local
{
	sz count = (sz)(vt.get_int("numElements") ?? (long)DEFAULT_VECTOR_COUNT);

	String elem_qual = "";
	if (try inner_arr = vt.get("inner"))
	{
		if (inner_arr.is_array() && inner_arr.len() > 0)
		{
			RawTypeInfo elem_info = extract_type_info(inner_arr.get_at(0));
			elem_qual = elem_info.qual_type;
		}
	}

	if (elem_qual.len == 0)
	{
		RawTypeInfo vt_info = extract_type_info(vt);
		elem_qual = vt_info.qual_type;
	}

	String elem_c3 = map_c_type_to_c3(allocator, elem_qual, options.type_prefix, false);
	if (elem_c3.len == 0)
	{
		elem_c3 = "float";
	}

	return string::format(allocator, "%s[<%d>]", elem_c3, (int)count);
}

<*
 Parses a function pointer C qualType string using depth-aware comma splitting.
*>
fn String parse_function_pointer_type(Allocator allocator, String qual_type, BindgenOptions options) @local
{
	String s = strip_clang_attributes(qual_type).trim();
	if (try last_paren = s.rindex_of_char(')'))
	{
		s = s[:last_paren + 1].trim();
	}
	String ret_c = "void";
	String rest = "";

	if (try idx = s.index_of("(*)"))
	{
		ret_c = s[:idx].trim();
		rest = s[idx + 3..].trim();
	}
	else if (try idx = s.index_of("(^)"))
	{
		ret_c = s[:idx].trim();
		rest = s[idx + 3..].trim();
	}
	else if (s.ends_with(")"))
	{
		int depth = 0;
		bool found = false;
		for (sz i = s.len; i > 0; i--)
		{
			char c = s[i - 1];
			if (c == ')')
			{
				depth++;
			}
			else if (c == '(')
			{
				depth--;
				if (depth == 0)
				{
					ret_c = s[:i - 1].trim();
					rest = s[i - 1..].trim();
					found = true;
					break;
				}
			}
		}
		if (!found)
		{
			return "fn void()";
		}
	}
	else
	{
		return "fn void()";
	}

	if (ret_c.len == 0)
	{
		ret_c = "void";
	}

	String ret_c3 = map_c_type_to_c3(allocator, ret_c, options.type_prefix, false);

	if (rest.starts_with("(") && rest.ends_with(")") && rest.len >= 2)
	{
		rest = rest[1 : ^2].trim();
	}

	if (rest.len == 0 || rest == "void")
	{
		return string::format(allocator, "fn %s()", ret_c3);
	}

	DString params_c3;
	params_c3.init(allocator);

	int depth = 0;
	sz arg_start = 0;
	for (sz i = 0; i < rest.len; i++)
	{
		char c = rest[i];
		switch (c)
		{
			case '(':
			case '[':
			case '{':
				depth++;
			case ')':
			case ']':
			case '}':
				if (depth > 0)
				{
					depth--;
				}
			case ',':
				if (depth == 0)
				{
					String p = rest[arg_start : i - arg_start].trim();
					if (p.len > 0 && p != "void")
					{
						if (params_c3.len() > 0)
						{
							params_c3.append(", ");
						}
						if (p == "..." || p.starts_with("..."))
						{
							params_c3.append("...");
						}
						else
						{
							params_c3.append(map_c_type_to_c3(allocator, p, options.type_prefix, true));
						}
					}
					arg_start = i + 1;
				}
			default:
				break;
		}
	}

	if (arg_start < rest.len)
	{
		String p = rest[arg_start..].trim();
		if (p.len > 0 && p != "void")
		{
			if (params_c3.len() > 0)
			{
				params_c3.append(", ");
			}
			if (p == "..." || p.starts_with("..."))
			{
				params_c3.append("...");
			}
			else
			{
				params_c3.append(map_c_type_to_c3(allocator, p, options.type_prefix, true));
			}
		}
	}

	return string::format(allocator, "fn %s(%s)", ret_c3, params_c3.str_view());
}

<*
 Records used external types that need alias, struct, or enum generation.
*>
fn void track_external_type_usage(
	String qual_type,
	HashSet{String}* target_types,
	HashMap{String, String}* external_typedefs,
	HashMap{String, Object*}* external_records,
	HashMap{String, Object*}* external_enums,
	HashSet{String}* used_external_types
) @local
{
	String base = extract_base_type_name(qual_type);
	if (base.len == 0 || is_fundamental_c_type(base) || target_types.contains(base))
	{
		return;
	}

	String c3_mapped = map_c_type_to_c3(tmem, base, "", false);
	if (is_c3_type(c3_mapped) || is_c3_type(base))
	{
		return;
	}

	String underscore_base = string::tformat("_%s", base);
	if (external_typedefs.has_key(base) || external_records.has_key(base) || external_enums.has_key(base))
	{
		used_external_types.add(base);
	}
	else if (external_records.has_key(underscore_base) || external_enums.has_key(underscore_base))
	{
		used_external_types.add(base);
	}
}

<*
 Parses a Clang ParmVarDecl into a CParam.
 Passes restrict qualifier to mark is_noalias.
 Disambiguates function pointers from pointers-to-arrays.
*>
fn CParam parse_param_decl(
	Allocator allocator,
	CTranslationUnit* tu,
	String fn_c3_name,
	Object* node,
	int index,
	BindgenOptions options,
	HashSet{String}* target_types,
	HashMap{String, String}* external_typedefs,
	HashMap{String, Object*}* external_records,
	HashMap{String, Object*}* external_enums,
	HashSet{String}* used_external_types
) @local
{
	String raw_name = node.get_string("name") ?? "";
	if (raw_name.len == 0)
	{
		raw_name = string::format(allocator, "arg%d", index);
	}

	RawTypeInfo tinfo = extract_type_info(node);
	String c_type = tinfo.qual_type;

	track_external_type_usage(c_type, target_types, external_typedefs, external_records, external_enums, used_external_types);

	bool is_noalias = false;
	String c3_type;

	if (is_c_function_pointer(c_type))
	{
		String cb_sig = parse_function_pointer_type(allocator, c_type, options);
		String cb_name = string::format(allocator, "%s%sFn", fn_c3_name.snake_to_pascal_copy(allocator), raw_name.snake_to_pascal_copy(allocator));
		cb_name = sanitize_c3_type_name(allocator, cb_name, options.type_prefix);
		tu.typedefs.push({
			.c_name = cb_name.copy(allocator),
			.c3_name = cb_name,
			.underlying_c = c_type.copy(allocator),
			.underlying_c3 = cb_sig,
			.is_func_ptr = true,
			.comment = ""
		});
		c3_type = cb_name;
	}
	else
	{
		c3_type = map_c_type_to_c3(allocator, c_type, options.type_prefix, true, tinfo.desugared_type, &is_noalias);
	}

	String c3_name = to_snake_case(allocator, raw_name);

	return {
		.name = c3_name,
		.c_type = c_type.copy(allocator),
		.c3_type = c3_type,
		.is_noalias = is_noalias
	};
}
<*
 Strips function/variable prefix based on options or module name.
*>
fn String strip_symbol_prefix(String name, BindgenOptions options) @local
{
	String c3_name = name;

	if (options.strip_func_prefix.len > 0)
	{
		String p = to_snake_case(tmem, options.strip_func_prefix).trim_right("_");
		String p_with_underscore = string::tformat("%s_", p);
		if (c3_name.starts_with(p_with_underscore))
		{
			c3_name = c3_name[p_with_underscore.len..];
		}
		else if (c3_name.starts_with(p))
		{
			c3_name = c3_name[p.len..].strip_prefix("_");
		}
	}
	else if (options.module_name.len > 0)
	{
		String mod_lower = to_snake_case(tmem, options.module_name).trim_right("_");
		String mod_prefix = string::tformat("%s_", mod_lower);
		String base_mod = mod_lower.trim_right("0123456789_");
		String base_prefix = base_mod.len > 0 ? string::tformat("%s_", base_mod) : "";

		if (c3_name.starts_with(mod_prefix))
		{
			c3_name = c3_name[mod_prefix.len..];
		}
		else if (base_prefix.len > 0 && c3_name.starts_with(base_prefix))
		{
			c3_name = c3_name[base_prefix.len..];
		}
	}

	if (c3_name.len == 0 || (c3_name[0] >= '0' && c3_name[0] <= '9'))
	{
		c3_name = name;
	}

	return c3_name;
}

<*
 Parses a Clang VarDecl object.
*>
fn void parse_var_decl(
	Allocator allocator,
	CTranslationUnit* tu,
	Object* node,
	BindgenOptions options,
	HashSet{String}* seen_names,
	HashSet{String}* target_types,
	HashMap{String, String}* external_typedefs,
	HashMap{String, Object*}* external_records,
	HashMap{String, Object*}* external_enums,
	HashSet{String}* used_external_types
) @local
{
	if (node.get_bool("isInvalid") ?? false)
	{
		return;
	}

	String c_name = node.get_string("name") ?? "";
	if (c_name.len == 0 || !seen_names.add(c_name))
	{
		return;
	}

	RawTypeInfo tinfo = extract_type_info(node);
	String c_type = tinfo.qual_type;
	if (c_type == "void")
	{
		return;
	}

	track_external_type_usage(c_type, target_types, external_typedefs, external_records, external_enums, used_external_types);

	String c3_type = map_c_type_to_c3(allocator, c_type, options.type_prefix, false, tinfo.desugared_type);
	String snake_name = to_snake_case(tmem, c_name);
	String c3_name = strip_symbol_prefix(snake_name, options);
	c3_name = sanitize_identifier(allocator, c3_name);

	HashSet{String} seen_var_names;
	seen_var_names.tinit();
	foreach (&v : tu.variables)
	{
		seen_var_names.add(v.c3_name);
	}
	foreach (&fn_item : tu.functions)
	{
		seen_var_names.add(fn_item.c3_name);
	}
	c3_name = deduplicate_name(&seen_var_names, c3_name, allocator);

	tu.variables.push({
		.c_name = c_name.copy(allocator),
		.c3_name = c3_name,
		.c_type = c_type.copy(allocator),
		.c3_type = c3_type,
		.comment = ""
	});
}

<*
 Parses a Clang FunctionDecl object.
*>
fn void parse_function_decl(
	Allocator allocator,
	CTranslationUnit* tu,
	Object* node,
	BindgenOptions options,
	HashSet{String}* seen_names,
	HashSet{String}* target_types,
	HashMap{String, String}* external_typedefs,
	HashMap{String, Object*}* external_records,
	HashMap{String, Object*}* external_enums,
	HashSet{String}* used_external_types
) @local
{
	if (node.get_bool("isInvalid") ?? false)
	{
		return;
	}

	String c_name = node.get_string("name") ?? "";
	if (c_name.len == 0)
	{
		return;
	}

	if (!seen_names.add(c_name))
	{
		return;
	}

	RawTypeInfo tinfo = extract_type_info(node);
	String qual_type = tinfo.qual_type;

	String ret_c = extract_function_return_type(qual_type);
	track_external_type_usage(ret_c, target_types, external_typedefs, external_records, external_enums, used_external_types);

	String ret_desugared = "";
	if (tinfo.desugared_type.len > 0)
	{
		ret_desugared = extract_function_return_type(tinfo.desugared_type);
	}
	String ret_c3 = map_c_type_to_c3(allocator, ret_c, options.type_prefix, false, ret_desugared);

	String snake_name = to_snake_case(tmem, c_name);
	String c3_name = strip_symbol_prefix(snake_name, options);
	c3_name = sanitize_identifier(allocator, c3_name);

	HashSet{String} seen_fn_names;
	seen_fn_names.tinit();
	foreach (&fn_item : tu.functions)
	{
		seen_fn_names.add(fn_item.c3_name);
	}
	c3_name = deduplicate_name(&seen_fn_names, c3_name, allocator);

	List{CParam} params;
	params.init(allocator);

	HashSet{String} seen_param_names;
	seen_param_names.tinit();

	bool is_variadic = qual_type.contains("...");

	if (try inner_arr = node.get("inner"))
	{
		if (inner_arr.is_array())
		{
			int param_idx = 0;
			for (sz i = 0; i < inner_arr.len(); i++)
			{
				Object* child = inner_arr.get_at(i);
				if (!child)
				{
					continue;
				}

				String child_kind = child.get_string("kind") ?? "";
				if (child_kind != "ParmVarDecl")
				{
					continue;
				}

				RawTypeInfo p_tinfo = extract_type_info(child);
				if (p_tinfo.qual_type == "void")
				{
					continue;
				}

				CParam p = parse_param_decl(allocator, tu, c3_name, child, param_idx++, options, target_types, external_typedefs, external_records, external_enums, used_external_types);
				p.name = deduplicate_name(&seen_param_names, p.name, allocator);
				params.push(p);
			}
		}
	}

	tu.functions.push({
		.c_name = c_name.copy(allocator),
		.c3_name = c3_name,
		.ret_type_c = ret_c.copy(allocator),
		.ret_type_c3 = ret_c3,
		.params = params,
		.is_variadic = is_variadic,
		.comment = ""
	});
}

fn bool is_type_name_defined(CTranslationUnit* tu, String name) @local
{
	if (is_c3_type(name) || constants::is_primitive(name))
	{
		return true;
	}
	foreach (&e : tu.enums)
	{
		if (e.c3_name == name) return true;
	}
	foreach (&st : tu.structs)
	{
		if (st.c3_name == name) return true;
	}
	foreach (&td : tu.typedefs)
	{
		if (td.c3_name == name) return true;
	}
	return false;
}

fn bool parse_record_fields(
	Allocator allocator,
	CTranslationUnit* tu,
	Object* node,
	String c_name,
	List{CField}* fields,
	BindgenOptions options,
	HashSet{String}* seen_names,
	HashSet{String}* target_types,
	HashMap{String, String}* external_typedefs,
	HashMap{String, Object*}* external_records,
	HashMap{String, Object*}* external_enums,
	HashMap{String, Object*}* anon_records,
	HashSet{String}* used_external_types
) @local
{
	Object* inner_arr = node.get("inner") ?? null;
	if (!inner_arr || !inner_arr.is_array())
	{
		return true;
	}

	for (sz i = 0; i < inner_arr.len(); i++)
	{
		Object* child = inner_arr.get_at(i);
		if (!child)
		{
			continue;
		}

		String child_kind = child.get_string("kind") ?? "";
		if (child_kind == "RecordDecl")
		{
			String sub_c_name = child.get_string("name") ?? "";
			if (sub_c_name.len > 0)
			{
				parse_record_decl_with_name(allocator, tu, child, sub_c_name, options, seen_names, target_types, external_typedefs, external_records, external_enums, anon_records, used_external_types);
			}
			else if (try id = child.get_string("id"))
			{
				anon_records.set(id, child);
			}
			continue;
		}

		if (child_kind == "EnumDecl")
		{
			String sub_c_name = child.get_string("name") ?? "";
			if (sub_c_name.len > 0)
			{
				parse_enum_decl_with_name(allocator, tu, child, sub_c_name, options, seen_names, target_types);
			}
			continue;
		}

		if (child_kind != "FieldDecl")
		{
			continue;
		}

		if (child.get_bool("isInvalid") ?? false)
		{
			return false;
		}

		RawTypeInfo f_tinfo = extract_type_info(child);
		String f_type_c = f_tinfo.qual_type;
		if (f_type_c == "void")
		{
			return false;
		}

		String f_name = child.get_string("name") ?? "";
		if (f_name.len == 0)
		{
			f_name = string::format(allocator, "_field%d", (int)i);
		}

		String f_type_c3;
		if (f_type_c.contains("(unnamed") || f_type_c.contains("(anonymous"))
		{
			String synth_name = string::format(allocator, "%s_%s", c_name, f_name);
			Object* anon_rec = null;
			if (f_tinfo.decl_id.len > 0)
			{
				anon_rec = anon_records.get(f_tinfo.decl_id) ?? null;
			}
			if (anon_rec)
			{
				parse_record_decl_with_name(allocator, tu, anon_rec, synth_name, options, seen_names, target_types, external_typedefs, external_records, external_enums, anon_records, used_external_types);
				f_type_c3 = sanitize_c3_type_name(allocator, synth_name, options.type_prefix);
			}
			else
			{
				f_type_c3 = f_type_c.contains("[") ? "void*[]" : "void*";
			}
		}
		else
		{
			track_external_type_usage(f_type_c, target_types, external_typedefs, external_records, external_enums, used_external_types);
			f_type_c3 = map_c_type_to_c3(allocator, f_type_c, options.type_prefix, false, f_tinfo.desugared_type, is_field: true);
		}

		String f_name_c3 = to_snake_case(allocator, f_name);

		fields.push({
			.c_name = f_name.copy(allocator),
			.c3_name = f_name_c3,
			.c_type = f_type_c.copy(allocator),
			.c3_type = f_type_c3,
			.bit_width = -1,
			.bit_offset = 0,
			.comment = ""
		});
	}

	return true;
}

<*
 Core RecordDecl parser with explicit name parameter to support typedef wrapping.
 Synthesizes named sub-records for anonymous union/struct fields.
 Emits all C structs as regular C3 structs, preventing invalid bitstructs.
*>
fn void parse_record_decl_with_name(
	Allocator allocator,
	CTranslationUnit* tu,
	Object* node,
	String c_name,
	BindgenOptions options,
	HashSet{String}* seen_names,
	HashSet{String}* target_types,
	HashMap{String, String}* external_typedefs,
	HashMap{String, Object*}* external_records,
	HashMap{String, Object*}* external_enums,
	HashMap{String, Object*}* anon_records,
	HashSet{String}* used_external_types
) @local
{
	if (c_name.len == 0)
	{
		return;
	}

	String tag = node.get_string("tagUsed") ?? "struct";
	bool is_union = (tag == "union");
	bool is_complete = node.get_bool("completeDefinition") ?? node.get_bool("isCompleteDefinition") ?? false;
	String c3_name = sanitize_c3_type_name(allocator, c_name, options.type_prefix);

	CStruct* existing = null;
	foreach (&st : tu.structs)
	{
		if (st.c3_name == c3_name || st.c_name == c_name)
		{
			existing = st;
			break;
		}
	}

	if (!existing)
	{
		HashSet{String} seen_type_names;
		seen_type_names.tinit();
		foreach (&e : tu.enums)
		{
			seen_type_names.add(e.c3_name);
		}
		c3_name = deduplicate_name(&seen_type_names, c3_name, allocator);
	}
	else
	{
		if (existing.is_opaque && is_complete)
		{
			List{CField} fields;
			fields.init(allocator);

			is_complete = parse_record_fields(allocator, tu, node, c_name, &fields, options, seen_names, target_types, external_typedefs, external_records, external_enums, anon_records, used_external_types);

			existing.is_opaque = !is_complete;
			existing.is_union = is_union;
			existing.is_bitfield = false;
			existing.fields = fields;
		}
		return;
	}

	seen_names.add(c_name);
	target_types.add(c_name);

	List{CField} fields;
	fields.init(allocator);

	if (is_complete)
	{
		is_complete = parse_record_fields(allocator, tu, node, c_name, &fields, options, seen_names, target_types, external_typedefs, external_records, external_enums, anon_records, used_external_types);
	}

	tu.structs.push({
		.c_name = c_name.copy(allocator),
		.c3_name = c3_name,
		.is_union = is_union,
		.is_opaque = !is_complete,
		.is_bitfield = false,
		.fields = fields,
		.comment = ""
	});
}

<*
 Core EnumDecl parser with explicit name parameter to support typedef wrapping.
 Deduplicates by both C name and sanitized C3 name to avoid enum shadowing.
*>
fn void parse_enum_decl_with_name(
	Allocator allocator,
	CTranslationUnit* tu,
	Object* node,
	String c_name,
	BindgenOptions options,
	HashSet{String}* seen_names,
	HashSet{String}* target_types
) @local
{
	if (c_name.len == 0)
	{
		return;
	}

	String c3_name = sanitize_c3_type_name(allocator, c_name, options.type_prefix);

	foreach (&e : tu.enums)
	{
		if (e.c3_name == c3_name || e.c_name == c_name)
		{
			return;
		}
	}

	HashSet{String} seen_struct_types;
	seen_struct_types.tinit();
	foreach (&st : tu.structs)
	{
		seen_struct_types.add(st.c3_name);
	}
	c3_name = deduplicate_name(&seen_struct_types, c3_name, allocator);

	if (!seen_names.add(c_name))
	{
		return;
	}
	seen_names.add(c3_name);

	target_types.add(c_name);
	target_types.add(c3_name);

	List{CEnumVariant} variants;
	variants.init(allocator);

	HashSet{String} seen_variant_names;
	seen_variant_names.tinit();

	bool is_sequential = true;
	long expected_val = 0;
	long min_val = 0;
	long max_val = 0;
	bool has_negative = false;

	if (try inner_arr = node.get("inner"))
	{
		if (inner_arr.is_array())
		{
			for (sz i = 0; i < inner_arr.len(); i++)
			{
				Object* child = inner_arr.get_at(i);
				if (!child)
				{
					continue;
				}

				String child_kind = child.get_string("kind") ?? "";
				if (child_kind != "EnumConstantDecl")
				{
					continue;
				}

				String v_name = child.get_string("name") ?? "";
				if (v_name.len == 0)
				{
					continue;
				}

				long val = expected_val;
				bool has_explicit = false;

				if (try val_obj = child.get("inner"))
				{
					if (val_obj.is_array() && val_obj.len() > 0)
					{
						has_explicit = true;
						if (Object* cexpr = val_obj.get_at(0))
						{
							if (try v_str = cexpr.get_string("value"))
							{
								if (try parsed_val = v_str.to_long())
								{
									val = parsed_val;
								}
							}
						}
					}
				}

				if (has_explicit && val != expected_val)
				{
					is_sequential = false;
				}

				String v_c3 = v_name;
				if (options.strip_enum_prefix.len > 0 && v_c3.starts_with(options.strip_enum_prefix))
				{
					v_c3 = v_c3[options.strip_enum_prefix.len..];
				}
				if (v_c3.len == 0 || (v_c3[0] >= '0' && v_c3[0] <= '9'))
				{
					v_c3 = v_name;
				}
				v_c3 = v_c3.to_upper_copy(allocator);

				v_c3 = deduplicate_name(&seen_variant_names, v_c3, allocator);

				if (val < min_val)
				{
					min_val = val;
				}
				if (val > max_val)
				{
					max_val = val;
				}
				if (val < 0)
				{
					has_negative = true;
				}

				variants.push({
					.c_name = v_name.copy(allocator),
					.c3_name = v_c3,
					.value = val,
					.has_explicit_value = has_explicit,
					.comment = ""
				});

				expected_val = val + 1;
			}
		}
	}

	String backing_type = "int";
	if (max_val > int::max)
	{
		if (has_negative || max_val > (long)uint::max)
		{
			backing_type = has_negative ? "long" : "ulong";
		}
		else
		{
			backing_type = "uint";
		}
	}
	else if (min_val < int::min)
	{
		backing_type = "long";
	}

	tu.enums.push({
		.c_name = c_name.copy(allocator),
		.c3_name = c3_name,
		.is_constdef = !is_sequential,
		.backing_type = backing_type,
		.variants = variants,
		.comment = ""
	});
}

<*
 Parses a TypedefDecl into either an alias (function pointers) or struct/type alias.
 Resolves anonymous RecordDecl / EnumDecl references by ID.
 Dispatches structured types (FunctionProtoType, VectorType) directly from Clang's AST.
*>
fn void parse_typedef_decl(
	Allocator allocator,
	CTranslationUnit* tu,
	Object* node,
	BindgenOptions options,
	HashSet{String}* seen_names,
	HashSet{String}* target_types,
	HashMap{String, Object*}* anon_records,
	HashMap{String, Object*}* anon_enums,
	HashMap{String, String}* external_typedefs,
	HashMap{String, Object*}* external_records,
	HashMap{String, Object*}* external_enums,
	HashSet{String}* used_external_types
) @local
{
	if (node.get_bool("isInvalid") ?? false)
	{
		return;
	}

	String c_name = node.get_string("name") ?? "";
	if (c_name.len == 0)
	{
		return;
	}

	if (try inner_arr = node.get("inner"))
	{
		if (inner_arr.is_array())
		{
			for (sz i = 0; i < inner_arr.len(); i++)
			{
				Object* child = inner_arr.get_at(i);
				if (!child)
				{
					continue;
				}

				String child_kind = child.get_string("kind") ?? "";

				if (child_kind == "ElaboratedType")
				{
					if (try owned_decl = child.get("ownedTagDecl"))
					{
						String tag_kind = owned_decl.get_string("kind") ?? "";
						String tag_name = owned_decl.get_string("name") ?? "";
						String tag_id = owned_decl.get_string("id") ?? "";

						if (tag_id.len > 0 && (tag_name.len == 0 || tag_name.starts_with("(unnamed") || tag_name.starts_with("(anonymous")))
						{
							if (tag_kind == "RecordDecl")
							{
								if (try anon_rec = anon_records.get(tag_id))
								{
									parse_record_decl_with_name(allocator, tu, anon_rec, c_name, options, seen_names, target_types, external_typedefs, external_records, external_enums, anon_records, used_external_types);
									return;
								}
							}
							else if (tag_kind == "EnumDecl")
							{
								if (try anon_e = anon_enums.get(tag_id))
								{
									parse_enum_decl_with_name(allocator, tu, anon_e, c_name, options, seen_names, target_types);
									return;
								}
							}
						}
					}
				}
				else if (child_kind == "RecordType")
				{
					if (try decl_obj = child.get("decl"))
					{
						String decl_id = decl_obj.get_string("id") ?? "";
						if (decl_id.len > 0)
						{
							if (try anon_rec = anon_records.get(decl_id))
							{
								parse_record_decl_with_name(allocator, tu, anon_rec, c_name, options, seen_names, target_types, external_typedefs, external_records, external_enums, anon_records, used_external_types);
								return;
							}
						}
					}
				}
				else if (child_kind == "EnumType")
				{
					if (try decl_obj = child.get("decl"))
					{
						String decl_id = decl_obj.get_string("id") ?? "";
						if (decl_id.len > 0)
						{
							if (try anon_e = anon_enums.get(decl_id))
							{
								parse_enum_decl_with_name(allocator, tu, anon_e, c_name, options, seen_names, target_types);
								return;
							}
						}
					}
				}
			}
		}
	}

	if (!seen_names.add(c_name))
	{
		return;
	}

	target_types.add(c_name);

	RawTypeInfo tinfo = extract_type_info(node);
	String qual_type = tinfo.qual_type;

	track_external_type_usage(qual_type, target_types, external_typedefs, external_records, external_enums, used_external_types);

	bool is_func_ptr = false;
	String c3_name = sanitize_c3_type_name(allocator, c_name, options.type_prefix);
	String c3_underlying;

	if (Object* fpt = find_descendant_by_kind(node, "FunctionProtoType"))
	{
		c3_underlying = format_function_proto_from_ast(allocator, fpt, options, target_types, external_typedefs, external_records, external_enums, used_external_types);
		is_func_ptr = true;
	}
	else if (Object* vt = find_descendant_by_kind(node, "VectorType"))
	{
		c3_underlying = format_vector_type_from_ast(allocator, vt, options);
	}
	else
	{
		is_func_ptr = is_c_function_pointer(qual_type);
		if (is_func_ptr)
		{
			c3_underlying = parse_function_pointer_type(allocator, qual_type, options);
		}
		else
		{
			c3_underlying = map_c_type_to_c3(allocator, qual_type, options.type_prefix, false, tinfo.desugared_type);
		}
	}

	// Break recursive pointer aliases (typedef struct Foo *Foo;)
	if (c3_underlying.ends_with("*") && extract_base_type_name(c3_underlying) == c3_name)
	{
		c3_underlying = "void*";
	}

	if (c3_name == c3_underlying || is_c3_type(c3_name) || is_c3_keyword(c3_name))
	{
		return;
	}

	foreach (&e : tu.enums)
	{
		if (e.c3_name == c3_name) return;
	}
	foreach (&st : tu.structs)
	{
		if (st.c3_name == c3_name) return;
	}

	tu.typedefs.push({
		.c_name = c_name.copy(allocator),
		.c3_name = c3_name,
		.underlying_c = qual_type.copy(allocator),
		.underlying_c3 = c3_underlying,
		.is_func_ptr = is_func_ptr,
		.comment = ""
	});
}

<*
 Parses the top-level Clang TranslationUnitDecl JSON into a CTranslationUnit.
 Filters symbols to only those originating in the specified target header.
 Emits aliases for referenced external typedefs and records.
*>
fn void parse_clang_ast_json(
	Allocator allocator,
	CTranslationUnit* tu,
	Object* root_obj,
	BindgenOptions options
)
{
	Object* inner_arr = null;
	if (try arr = root_obj.get("inner"))
	{
		inner_arr = arr;
	}
	if (!inner_arr || !inner_arr.is_array())
	{
		return;
	}

	HashSet{String} seen_names;
	seen_names.init(allocator);
	defer seen_names.free();

	HashSet{String} target_types;
	target_types.init(allocator);
	defer target_types.free();

	HashMap{String, Object*} anon_records;
	anon_records.init(allocator);
	defer anon_records.free();

	HashMap{String, Object*} anon_enums;
	anon_enums.init(allocator);
	defer anon_enums.free();

	HashMap{String, String} external_typedefs;
	external_typedefs.init(allocator);
	defer external_typedefs.free();

	HashMap{String, Object*} external_records;
	external_records.init(allocator);
	defer external_records.free();

	HashMap{String, Object*} external_enums;
	external_enums.init(allocator);
	defer external_enums.free();

	HashSet{String} used_external_types;
	used_external_types.init(allocator);
	defer used_external_types.free();

	// Pass 1: Index typedefs and records across entire translation unit
	for (sz i = 0; i < inner_arr.len(); i++)
	{
		Object* node = inner_arr.get_at(i);
		if (!node)
		{
			continue;
		}

		if (node.get_bool("isInvalid") ?? false)
		{
			continue;
		}

		String kind = node.get_string("kind") ?? "";
		if (kind == "TypedefDecl")
		{
			String td_name = node.get_string("name") ?? "";
			if (td_name.len > 0)
			{
				RawTypeInfo tinfo = extract_type_info(node);
				String desugared = tinfo.desugared_type.len > 0 ? tinfo.desugared_type : tinfo.qual_type;
				if (desugared.len > 0)
				{
					external_typedefs.set(td_name.copy(allocator), desugared.copy(allocator));
				}
			}
			continue;
		}

		if (kind == "RecordDecl")
		{
			String r_name = node.get_string("name") ?? "";
			if (r_name.len > 0)
			{
				external_records.set(r_name.copy(allocator), node);
			}
			if (try id = node.get_string("id"))
			{
				anon_records.set(id, node);
			}
			continue;
		}

		if (kind == "EnumDecl")
		{
			String e_name = node.get_string("name") ?? "";
			if (e_name.len > 0)
			{
				external_enums.set(e_name.copy(allocator), node);
			}
			if (try id = node.get_string("id"))
			{
				anon_enums.set(id, node);
			}
			continue;
		}
	}

	String current_file = options.header_path;

	// Pass 2: Parse declarations from the target header
	for (sz i = 0; i < inner_arr.len(); i++)
	{
		Object* node = inner_arr.get_at(i);
		if (!node)
		{
			continue;
		}

		if (node.get_bool("isImplicit") ?? false)
		{
			continue;
		}

		String file_loc = extract_node_file(node);
		if (file_loc.len > 0)
		{
			current_file = file_loc;
		}

		if (!is_target_file(current_file, options.header_path))
		{
			continue;
		}

		String kind = node.get_string("kind") ?? "";
		switch (kind)
		{
			case "FunctionDecl":
				parse_function_decl(allocator, tu, node, options, &seen_names, &target_types, &external_typedefs, &external_records, &external_enums, &used_external_types);
			case "VarDecl":
				parse_var_decl(allocator, tu, node, options, &seen_names, &target_types, &external_typedefs, &external_records, &external_enums, &used_external_types);
			case "RecordDecl":
				{
					String c_name = node.get_string("name") ?? "";
					if (c_name.len == 0)
					{
						if (try id = node.get_string("id"))
						{
							anon_records.set(id, node);
						}
					}
					else
					{
						parse_record_decl_with_name(allocator, tu, node, c_name, options, &seen_names, &target_types, &external_typedefs, &external_records, &external_enums, &anon_records, &used_external_types);
					}
				}
			case "EnumDecl":
				{
					String c_name = node.get_string("name") ?? "";
					if (c_name.len == 0)
					{
						if (try id = node.get_string("id"))
						{
							anon_enums.set(id, node);
						}
					}
					else
					{
						parse_enum_decl_with_name(allocator, tu, node, c_name, options, &seen_names, &target_types);
					}
				}
			case "TypedefDecl":
				parse_typedef_decl(allocator, tu, node, options, &seen_names, &target_types, &anon_records, &anon_enums, &external_typedefs, &external_records, &external_enums, &used_external_types);
			default:
				break;
		}
	}

	// Pass 3: Synthesize referenced external types
	used_external_types.@each(; ext_name)
	{
		String underscore_ext = string::tformat("_%s", ext_name);
		Object* rec_node = external_records.get(ext_name) ?? external_records.get(underscore_ext) ?? null;
		Object* enum_node = external_enums.get(ext_name) ?? external_enums.get(underscore_ext) ?? null;

		if (rec_node)
		{
			parse_record_decl_with_name(allocator, tu, rec_node, ext_name, options, &seen_names, &target_types, &external_typedefs, &external_records, &external_enums, &anon_records, &used_external_types);
		}
		else if (enum_node)
		{
			parse_enum_decl_with_name(allocator, tu, enum_node, ext_name, options, &seen_names, &target_types);
		}
		else if (try desugared_c = external_typedefs.get(ext_name))
		{
			String c3_name = sanitize_c3_type_name(allocator, ext_name, options.type_prefix);
			String c3_underlying = map_c_type_to_c3(allocator, desugared_c, options.type_prefix, false);

			if (c3_underlying.ends_with("*") && extract_base_type_name(c3_underlying) == c3_name)
			{
				c3_underlying = "void*";
			}

			bool conflicts = false;
			foreach (&st : tu.structs)
			{
				if (st.c3_name == c3_name)
				{
					conflicts = true;
					break;
				}
			}
			foreach (&e : tu.enums)
			{
				if (e.c3_name == c3_name)
				{
					conflicts = true;
					break;
				}
			}

			if (!conflicts && c3_name != c3_underlying && !is_c3_type(c3_name) && !is_c3_keyword(c3_name) && seen_names.add(ext_name))
			{
				tu.typedefs.push({
					.c_name = ext_name.copy(allocator),
					.c3_name = c3_name,
					.underlying_c = desugared_c.copy(allocator),
					.underlying_c3 = c3_underlying,
					.is_func_ptr = false,
					.comment = ""
				});
				target_types.add(ext_name);
			}
		}
	};
}