module lsp::bindgen;

import std;
import analyzer::core::constants;

<*
 Extracts the source file path from a Clang AST location object.
 @param [&in] loc : "Clang AST location object."
 @return "File path string or empty if unavailable."
*>
fn String extract_file_from_loc(Object* loc) @local
{
	return loc.get_string("file") ?? loc.get("expansionLoc").get_string("file") ?? "";
}

<*
 Extracts file path from a node's loc object.
 @param node : "Clang AST JSON object."
 @return     "File path string or empty if unavailable."
*>
fn String extract_node_file(Object* node) @local
{
	return extract_file_from_loc(node.get("loc")) ?? "";
}

<*
 Determines if a node originated from the target header rather than system includes.
 @param node_file : "File path where the AST node was defined."
 @param options   : "Bindgen configuration options."
 @return          "True if node should be included in bindings."
*>
fn bool is_target_file(String node_file, BindgenOptions options) @private
{
	if (node_file.len == 0)
	{
		return false;
	}

	if (options.target_dir.len > 0 && node_file.starts_with(options.target_dir))
	{
		return true;
	}

	if (node_file == options.header_path)
	{
		return true;
	}

	return header_basename(node_file) == header_basename(options.header_path);
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

<*
 @param [&in] node : "Clang AST node with an optional `type` object."
*>
fn RawTypeInfo extract_type_info(Object* node) @private
{
	RawTypeInfo info = {
		.qual_type = "void*",
		.desugared_type = "",
		.decl_id = ""
	};
	Object*? type_obj = node.get("type");
	if (catch type_obj)
	{
		return info;
	}

	info.qual_type = type_obj.get_string("qualType") ?? "void*";
	info.desugared_type = type_obj.get_string("desugaredQualType") ?? "";

	info.decl_id = type_obj.get("decl").get_string("id") ?? "";
	return info;
}

<*
 Recursively finds the first descendant AST node matching target_kind in inner.
 @param [&in] node : "Node to search below."
 @param through_typedefs : "Whether to search the types other typedefs name."
*>
fn Object*? find_descendant_by_kind(Object* node, String target_kind, bool through_typedefs = true) @local
{
	if (!through_typedefs && (node.get_string("kind") ?? "") == "TypedefType") return NOT_FOUND~;
	String[2] tag_keys = { "decl", "ownedTagDecl" };
	foreach (key : tag_keys)
	{
		if (try child = node.get(key))
		{
			if ((child.get_string("kind") ?? "") == target_kind)
			{
				return child;
			}
			if (try found = find_descendant_by_kind(child, target_kind, through_typedefs))
			{
				return found;
			}
		}
	}

	foreach (child : inner_nodes(node))
	{
		if ((child.get_string("kind") ?? "") == target_kind)
		{
			return child;
		}
		if (try found = find_descendant_by_kind(child, target_kind, through_typedefs))
		{
			return found;
		}
	}

	return NOT_FOUND~;
}

<*
 Children in a node's "inner" array; empty when it has none.
*>
fn Object*[] inner_nodes(Object* node) @private
{
	Object*? inner = node.get("inner");
	if (catch inner) return {};
	if (!inner.is_array()) return {};
	return inner.array.array_view();
}

<*
 First child in a node's "inner" array.
*>
fn Object*? first_inner(Object* node) @private
{
	Object*[] children = inner_nodes(node);
	if (children.len == 0) return NOT_FOUND~;
	return children[0];
}

<*
 Resolves an incomplete AST record or enum declaration against its full definition in an anonymous decl map.
 @param [&in] node : "Record or enum declaration."
*>
fn Object* resolve_complete_decl(Object* node, HashMap{String, Object*}* anon_map) @local
{
	bool is_comp = node.get_bool("completeDefinition") ?? node.get_bool("isCompleteDefinition") ?? false;
	if (is_comp)
	{
		return node;
	}
	return anon_map.get(node.get_string("id")) ?? node;
}

<*
 Returns true if a C tag name is anonymous or compiler-generated.
*>
fn bool is_anonymous_tag_name(String name) @local
{
	return name.len == 0 || name.contains("(unnamed") || name.contains("(anonymous");
}

<*
 Indexes an external record or enum declaration and records its anonymous ID mapping.
 @param [&in] node : "Record or enum declaration."
*>
fn void index_tag_decl(
	Allocator allocator,
	String name,
	Object* node,
	HashMap{String, Object*}* external_map,
	HashMap{String, Object*}* anon_map
) @local
{
	Object* full = resolve_complete_decl(node, anon_map);
	if (name.len > 0)
	{
		external_map.set(name.copy(allocator), full);
	}
	if (try id = full.get_string("id"))
	{
		anon_map.set(id, full);
	}
}

<*
 Looks up an external record or enum by name or underscore prefix, falling back to desugared typedef base names.
*>
fn Object*? find_external_tag(
	String name,
	HashMap{String, Object*}* tag_map,
	HashMap{String, String}* typedef_map
) @local
{
	Object*? node = tag_map.get(name) ?? tag_map.get(string::tformat("_%s", name));
	if (try node) return node;

	String desug = typedef_map.get(name)!;
	if (desug.contains("*") || desug.contains("[")) return NOT_FOUND~;
	String base_desug = extract_base_type_name(desug);
	return tag_map.get(base_desug) ?? tag_map.get(string::tformat("_%s", base_desug));
}

<*
 Integer value of the first ConstantExpr, else IntegerLiteral, below `node`.
*>
fn long? constant_value(Object* node) @local
{
	Object* expr = find_descendant_by_kind(node, "ConstantExpr") ?? find_descendant_by_kind(node, "IntegerLiteral")!;
	return expr.get_string("value")!.to_long();
}

<*
 Extracts the return type from a Clang function qualType string.
 Uses backward parenthesis matching to avoid terminating on nested attributes.
 @param qual_type : "Function signature string from Clang."
 @return          "C return type string."
*>
fn String extract_function_return_type(String qual_type) @local
{
	String s = function_signature(qual_type);
	sz? open = last_paren_group_open(s);
	if (catch open) return "void";
	String ret = s[:open].trim();
	return ret.len > 0 ? ret : "void";
}

<*
 Function type string without attributes or anything after its parameter list.
*>
fn String function_signature(String qual_type) @local
{
	String s = strip_clang_attributes(qual_type).trim();
	if (try last_paren = s.rindex_of_char(')')) s = s[:last_paren + 1].trim();
	return s;
}

<*
 State shared by the declaration parsers of one translation unit.
*>
struct ParseContext @local
{
	Allocator allocator;
	CTranslationUnit* tu;
	BindgenOptions options;
	HashSet{String} seen_names;
	HashSet{String} target_types;
	HashSet{String} function_types;
	HashMap{String, Object*} anon_records;
	HashMap{String, Object*} anon_enums;
	HashMap{String, String} unnamed_record_names;
	HashMap{String, String} external_typedefs;
	HashMap{String, Object*} external_records;
	HashMap{String, Object*} external_enums;
	HashSet{String} used_external_types;
}

fn void ParseContext.init(&self, Allocator allocator, CTranslationUnit* tu, BindgenOptions options)
{
	*self = { .allocator = allocator, .tu = tu, .options = options };
	@init_containers(self, allocator);
}

fn void ParseContext.free(&self) => @free_containers(self);

<*
 Formats a C3 function signature directly from a Clang FunctionProtoType AST node.
 Tracks return and parameter types for external alias/struct synthesis.
*>
fn String ParseContext.format_function_proto_from_ast(&self, Object* fpt)
{
	Object*[] inner = inner_nodes(fpt);
	if (inner.len == 0)
	{
		return "fn void()";
	}

	RawTypeInfo ret_info = extract_type_info(inner[0]);
	String ret_c3 = self.map_type(ret_info.qual_type, ret_info.desugared_type);

	DString params_c3;
	params_c3.init(self.allocator);

	foreach (param_node : inner[1..])
	{
		RawTypeInfo p_info = extract_type_info(param_node);
		if (p_info.qual_type == "void")
		{
			continue;
		}

		String p_c3 = self.map_type(p_info.qual_type, p_info.desugared_type, is_param: true);
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

	return string::format(self.allocator, "fn %s(%s)", ret_c3, params_c3.str_view());
}

<*
 Registers an alias named `<Owner><Member>Fn` for an inline function pointer type and returns that name.
*>
fn String ParseContext.push_callback_alias(&self, String owner_name, String member_name, String c_type)
{
	String cb_name = sanitize_c3_type_name(self.allocator, string::tformat("%s_%s_fn", owner_name, member_name), self.options.type_prefix);
	self.tu.typedefs.push({
		.c_name = cb_name.copy(self.allocator),
		.c3_name = cb_name,
		.underlying_c = c_type.copy(self.allocator),
		.underlying_c3 = self.parse_function_pointer_type(c_type),
		.is_func_ptr = true,
		.comment = ""
	});
	return cb_name;
}

<*
 Translates a C function or function pointer type string into a C3 `fn` signature.
*>
fn String ParseContext.parse_function_pointer_type(&self, String qual_type)
{
	String s = function_signature(qual_type);
	String ret_c;
	String params;
	if (try marker = s.index_of("(*)") ?? s.index_of("(^)"))
	{
		ParenSpan? span = find_paren_span(s, marker + 3);
		if (catch span) return "fn void()";
		ret_c = string::tformat("%s%s", s[:marker], s[span.close + 1..]).trim();
		params = s[span.open + 1 : span.close - span.open - 1];
	}
	else
	{
		sz? open = last_paren_group_open(s);
		if (catch open) return "fn void()";
		ret_c = s[:open].trim();
		params = s[open + 1..^2];
	}
	String ret_c3 = self.map_type(ret_c.len > 0 ? ret_c : "void", "");

	DString params_c3;
	params_c3.init(self.allocator);
	foreach (param : split_top_level_commas(params))
	{
		if (param.len == 0 || param == "void") continue;
		if (params_c3.len() > 0) params_c3.append(", ");
		params_c3.append(param.starts_with("...") ? "..." : self.map_type(param, "", is_param: true));
	}
	return string::format(self.allocator, "fn %s(%s)", ret_c3, params_c3.str_view());
}

<*
 Maps a C type to C3, ignoring the desugared type when `c_type` names a typedef declared in the target header
 or a SIMD vector, so the emitted alias is kept. Bitfields always map to the underlying type, which sizes their storage.
 External types are tracked only when the result refers to them by name. A function typedef already
 maps to a C3 function pointer, so one pointer level is dropped.
*>
fn String ParseContext.map_type(&self, String c_type, String desugared_type, bool is_param = false, bool is_field = false, bool is_bitfield = false, bool* out_is_noalias = null)
{
	String base = extract_base_type_name(c_type);
	if (!is_bitfield && (self.target_types.contains(base) || @ok(simd_vector_shape(desugared_type)))) desugared_type = "";
	if (desugared_type.len == 0 || !is_fundamental_c_type(extract_base_type_name(desugared_type))) self.track_external_type_usage(c_type);
	if (self.function_types.contains(base)) c_type = c_type[:c_type.rindex_of_char('*') ?? c_type.len];
	return map_c_type_to_c3(self.allocator, c_type, self.options.type_prefix, self.tu, is_param, desugared_type, out_is_noalias, is_field);
}

<*
 Records used external types that need alias, struct, or enum generation.
*>
fn void ParseContext.track_external_type_usage(&self, String qual_type)
{
	String base = extract_base_type_name(qual_type);
	if (base.len == 0 || is_fundamental_c_type(base) || self.target_types.contains(base))
	{
		return;
	}

	String c3_mapped = map_c_type_to_c3(tmem, base, "", self.tu);
	if (is_c3_type(c3_mapped) || is_c3_type(base))
	{
		return;
	}

	String underscore_base = string::tformat("_%s", base);
	if (self.external_typedefs.has_key(base) || self.external_records.has_key(base) || self.external_enums.has_key(base))
	{
		self.used_external_types.add(base);
	}
	else if (self.external_records.has_key(underscore_base) || self.external_enums.has_key(underscore_base))
	{
		self.used_external_types.add(base);
	}
}

<*
 Parses a Clang ParmVarDecl into a CParam.
 Passes restrict qualifier to mark is_noalias.
 Disambiguates function pointers from pointers-to-arrays.
*>
fn CParam ParseContext.parse_param_decl(&self, String fn_c3_name, Object* node, int index)
{
	String raw_name = node.get_string("name") ?? "";
	if (raw_name.len == 0)
	{
		raw_name = string::format(self.allocator, "arg%d", index);
	}

	RawTypeInfo tinfo = extract_type_info(node);
	String c_type = tinfo.qual_type;

	bool is_noalias = false;
	String c3_type;

	if (is_c_function_pointer(c_type))
	{
		c3_type = self.push_callback_alias(fn_c3_name, raw_name, c_type);
	}
	else
	{
		c3_type = self.map_type(c_type, tinfo.desugared_type, is_param: true, out_is_noalias: &is_noalias);
	}

	String c3_name = to_snake_case(self.allocator, raw_name);

	return {
		.name = c3_name,
		.c_type = c_type.copy(self.allocator),
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
fn void ParseContext.parse_var_decl(&self, Object* node)
{
	if (node.get_bool("isInvalid") ?? false)
	{
		return;
	}

	String c_name = node.get_string("name") ?? "";
	if (c_name.len == 0 || !self.seen_names.add(c_name))
	{
		return;
	}

	RawTypeInfo tinfo = extract_type_info(node);
	String c_type = tinfo.qual_type;
	if (c_type == "void")
	{
		return;
	}

	String c3_type = self.map_type(c_type, tinfo.desugared_type);
	String snake_name = to_snake_case(tmem, c_name);
	String c3_name = strip_symbol_prefix(snake_name, self.options);
	c3_name = sanitize_identifier(self.allocator, c3_name);

	HashSet{String} seen_var_names;
	seen_var_names.tinit();
	foreach (&v : self.tu.variables)
	{
		seen_var_names.add(v.c3_name);
	}
	foreach (&fn_item : self.tu.functions)
	{
		seen_var_names.add(fn_item.c3_name);
	}
	c3_name = deduplicate_name(&seen_var_names, c3_name, self.allocator);

	self.tu.variables.push({
		.c_name = c_name.copy(self.allocator),
		.c3_name = c3_name,
		.c_type = c_type.copy(self.allocator),
		.c3_type = c3_type,
		.comment = ""
	});
}

<*
 Parses a Clang FunctionDecl object.
*>
fn void ParseContext.parse_function_decl(&self, Object* node)
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

	if (!self.seen_names.add(c_name))
	{
		return;
	}

	RawTypeInfo tinfo = extract_type_info(node);
	String qual_type = tinfo.qual_type;

	String ret_c = extract_function_return_type(qual_type);

	String ret_desugared = "";
	if (tinfo.desugared_type.len > 0)
	{
		ret_desugared = extract_function_return_type(tinfo.desugared_type);
	}
	String ret_c3 = self.map_type(ret_c, ret_desugared);

	String snake_name = to_snake_case(tmem, c_name);
	String c3_name = strip_symbol_prefix(snake_name, self.options);
	c3_name = sanitize_identifier(self.allocator, c3_name);

	HashSet{String} seen_fn_names;
	seen_fn_names.tinit();
	foreach (&fn_item : self.tu.functions)
	{
		seen_fn_names.add(fn_item.c3_name);
	}
	c3_name = deduplicate_name(&seen_fn_names, c3_name, self.allocator);

	List{CParam} params;
	params.init(self.allocator);

	HashSet{String} seen_param_names;
	seen_param_names.tinit();

	bool is_variadic = qual_type.contains("...");

	int param_idx = 0;
	foreach (child : inner_nodes(node))
	{
		if ((child.get_string("kind") ?? "") != "ParmVarDecl" || extract_type_info(child).qual_type == "void")
		{
			continue;
		}

		CParam p = self.parse_param_decl(c3_name, child, param_idx++);
		p.name = deduplicate_name(&seen_param_names, p.name, self.allocator);
		params.push(p);
	}

	self.tu.functions.push({
		.c_name = c_name.copy(self.allocator),
		.c3_name = c3_name,
		.ret_type_c = ret_c.copy(self.allocator),
		.ret_type_c3 = ret_c3,
		.params = params,
		.is_variadic = is_variadic,
		.comment = ""
	});
}

fn bool is_type_name_defined(CTranslationUnit* tu, String name) @local
{
	return is_c3_type(name) || constants::is_primitive(name) || tu.has_type_name(name);
}

<*
 @param c_object : "C expression of an object of the record, or empty if it cannot be named."
*>
fn bool ParseContext.parse_record_fields(&self, Object* node, String c_name, String c_object, List{CField}* fields)
{
	Object*? last_anon_rec = NOT_FOUND~;

	foreach (i, child : inner_nodes(node))
	{
		String child_kind = child.get_string("kind") ?? "";
		if (child_kind == "RecordDecl")
		{
			String sub_c_name = child.get_string("name") ?? "";
			if (sub_c_name.len > 0)
			{
				self.parse_record_decl_with_name(child, sub_c_name, record_c_object(self.allocator, child, sub_c_name));
			}
			else
			{
				last_anon_rec = child;
				if (try id = child.get_string("id"))
				{
					self.anon_records.set(id, child);
				}
			}
			continue;
		}

		if (child_kind == "EnumDecl")
		{
			String sub_c_name = child.get_string("name") ?? "";
			if (sub_c_name.len > 0)
			{
				self.parse_enum_decl_with_name(child, sub_c_name);
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

		int bit_width = (child.get_bool("isBitfield") ?? false) ? (int)(constant_value(child) ?? -1) : -1;

		String raw_f_name = child.get_string("name") ?? "";
		String f_name = raw_f_name;
		if (f_name.len == 0 && bit_width < 0)
		{
			f_name = string::format(self.allocator, "_field%d", (int)i);
		}

		String f_type_c3;
		if (is_anonymous_tag_name(f_type_c))
		{
			String synth_name = string::format(self.allocator, "%s_%s", c_name, f_name);
			if (try anon_rec = self.anon_records.get(f_tinfo.decl_id) ?? last_anon_rec)
			{
				self.parse_record_decl_with_name(anon_rec, synth_name, member_c_object(self.allocator, c_object, raw_f_name, f_type_c));
				f_type_c3 = sanitize_c3_type_name(self.allocator, synth_name, self.options.type_prefix);
				if (try open_b = f_type_c.index_of_char('['))
				{
					f_type_c3 = string::format(self.allocator, "%s%s", f_type_c3, f_type_c[open_b..]);
				}
				else if (f_type_c.ends_with("*"))
				{
					f_type_c3 = string::format(self.allocator, "%s*", f_type_c3);
				}
			}
			else
			{
				if (f_type_c.contains("enum ") && !f_type_c.contains("*"))
				{
					f_type_c3 = "int";
				}
				else if (f_type_c.contains("enum ") && f_type_c.contains("*"))
				{
					f_type_c3 = "int*";
				}
				else
				{
					f_type_c3 = f_type_c.contains("[") ? "void*[]" : "void*";
				}
			}
		}
		else if (f_type_c.contains("(*)") && is_c_function_pointer(f_type_c))
		{
			f_type_c3 = self.push_callback_alias(c_name, f_name, f_type_c);
		}
		else
		{
			f_type_c3 = self.map_type(f_type_c, f_tinfo.desugared_type, is_field: true, is_bitfield: bit_width >= 0);
		}

		String f_name_c3 = f_name.len > 0 ? to_snake_case(self.allocator, f_name) : "";

		fields.push({
			.c_name = raw_f_name.copy(self.allocator),
			.c3_name = f_name_c3,
			.c_type = f_type_c.copy(self.allocator),
			.c3_type = f_type_c3,
			.bit_width = bit_width,
			.bit_offset = 0,
			.comment = ""
		});
	}

	return true;
}

<*
 Calculates bit offsets for bitfields and returns true if all fields are bitfields that share one
 storage unit, so the record can be a bitstruct.
*>
fn bool compute_record_bitfields(List{CField}* fields, int c_long_bits, bool ms_bitfields) @local
{
	if (ms_bitfields) return compute_ms_bitfields(fields, c_long_bits);
	bool has_any_bitfield = false;
	bool has_non_bitfield = false;
	int current_container_cap = 64;
	int current_bit_offset = 0;

	foreach (&f : *fields)
	{
		if (f.bit_width < 0)
		{
			has_non_bitfield = true;
			current_bit_offset = 0;
			continue;
		}

		has_any_bitfield = true;
		int cap = type_bit_capacity(f.c3_type, c_long_bits);
		if (cap > current_container_cap)
		{
			current_container_cap = cap;
		}

		if (f.bit_width == 0)
		{
			current_bit_offset = 0;
			continue;
		}

		if (current_bit_offset + f.bit_width > current_container_cap)
		{
			current_bit_offset = 0;
		}

		f.bit_offset = current_bit_offset;
		current_bit_offset += f.bit_width;
	}

	return has_any_bitfield && !has_non_bitfield;
}

<*
 MS bitfield layout: a bitfield lives in a storage unit of its declared type, and a new unit starts
 when the declared type's size changes, when the field does not fit in the bits left, or after a
 zero-width bitfield.
*>
fn bool compute_ms_bitfields(List{CField}* fields, int c_long_bits) @local
{
	bool has_non_bitfield;
	int unit = -1;
	int unit_bits;
	int used_bits;
	foreach (&f : *fields)
	{
		if (f.bit_width < 0)
		{
			has_non_bitfield = true;
			unit_bits = 0;
			continue;
		}
		int bits = type_bit_capacity(f.c3_type, c_long_bits);
		if (f.bit_width > 0 && (bits != unit_bits || used_bits + f.bit_width > unit_bits))
		{
			unit++;
			unit_bits = bits;
			used_bits = 0;
		}
		f.storage_unit = unit;
		f.storage_bits = bits;
		f.bit_offset = used_bits;
		used_bits += f.bit_width;
		if (f.bit_width == 0) unit_bits = 0;
	}
	return !has_non_bitfield && unit == 0;
}

<*
 C expression of an object of the record named `c_name`, spelled with its tag when `c_name` is the
 tag and as a typedef otherwise.
*>
fn String record_c_object(Allocator allocator, Object* node, String c_name) @local
{
	if ((node.get_string("name") ?? "") != c_name) return string::format(allocator, "(*(%s*)0)", c_name);
	return string::format(allocator, "(*(%s %s*)0)", node.get_string("tagUsed") ?? "struct", c_name);
}

<*
 C expression of the record held by member `field_name` of `parent_object`, an object of the parent
 record, or the parent object itself for an anonymous member, whose fields belong to the parent.
 @param field_type : "C type of the member: the record, a pointer to it, or an array of it."
*>
fn String member_c_object(Allocator allocator, String parent_object, String field_name, String field_type) @local
{
	if (parent_object.len == 0 || field_name.len == 0) return parent_object;
	if (field_type.ends_with("*")) return string::format(allocator, "(*%s.%s)", parent_object, field_name);
	DString out;
	out.init(allocator);
	out.appendf("%s.%s", parent_object, field_name);
	out.append_repeat("[0]", field_type.count("["));
	return out.str_view();
}

<*
 Whether a FieldDecl of the RecordDecl carries an aligned attribute.
*>
fn bool has_aligned_field(Object* node) @local
{
	foreach (child : inner_nodes(node))
	{
		if ((child.get_string("kind") ?? "") != "FieldDecl") continue;
		foreach (attr : inner_nodes(child))
		{
			if ((attr.get_string("kind") ?? "") == "AlignedAttr") return true;
		}
	}
	return false;
}

<*
 Extracts packed and alignment attributes from a RecordDecl node.
*>
fn void parse_record_attributes(Object* node, bool* out_is_packed, uint* out_alignment) @local
{
	foreach (child : inner_nodes(node))
	{
		String k = child.get_string("kind") ?? "";
		if (k == "PackedAttr" || k == "MaxFieldAlignmentAttr")
		{
			*out_is_packed = true;
		}
		else if (k == "AlignedAttr")
		{
			uint align_val = (uint)(constant_value(child) ?? 16);
			if (align_val > *out_alignment)
			{
				*out_alignment = align_val;
			}
		}
	}
}

<*
 Core RecordDecl parser with explicit name parameter to support typedef wrapping.
 Synthesizes named sub-records for anonymous union/struct fields.
 Emits all C structs as regular C3 structs, preventing invalid bitstructs.
 @param c_object : "C expression of an object of the record, or empty if it cannot be named."
*>
fn void ParseContext.parse_record_decl_with_name(&self, Object* node, String c_name, String c_object)
{
	if (c_name.len == 0)
	{
		return;
	}

	String tag = node.get_string("tagUsed") ?? "struct";
	bool is_union = (tag == "union");
	bool is_complete = node.get_bool("completeDefinition") ?? node.get_bool("isCompleteDefinition") ?? false;
	String c3_name = tag_c3_name(self.allocator, c_name, self.options.type_prefix, &self.tu.underscored_tags);

	bool is_packed = false;
	uint alignment = 0;
	parse_record_attributes(node, &is_packed, &alignment);

	String record_c_name;
	sz? existing_idx = find_struct_index(self.tu, c3_name, c_name);
	if (try existing_idx)
	{
		CStruct* existing = &self.tu.structs[existing_idx];
		if (!existing.is_opaque || !is_complete) return;
		record_c_name = existing.c_name;
		c3_name = existing.c3_name;
	}
	else
	{
		HashSet{String} seen_type_names;
		seen_type_names.tinit();
		self.tu.add_type_names(&seen_type_names, structs: false, typedefs: false);
		c3_name = deduplicate_name(&seen_type_names, c3_name, self.allocator);
		self.seen_names.add(c_name);
		self.target_types.add(c_name);
		record_c_name = c_name.copy(self.allocator);
	}

	List{CField} fields;
	fields.init(self.allocator);

	if (is_complete)
	{
		is_complete = self.parse_record_fields(node, c_name, c_object, &fields);
	}

	bool is_all_bitfields = compute_record_bitfields(&fields, self.tu.c_long_bits, self.tu.ms_bitfields);
	if (!is_packed && !self.tu.ms_bitfields)
	{
		foreach (f : fields)
		{
			if (f.bit_width >= 0)
			{
				uint align_bytes = (uint)(type_bit_capacity(f.c3_type, self.tu.c_long_bits) / 8);
				if (align_bytes > alignment) alignment = align_bytes;
			}
		}
	}

	CStruct record = {
		.c_name = record_c_name,
		.c3_name = c3_name,
		.is_union = is_union,
		.is_opaque = !is_complete,
		.is_bitfield = is_all_bitfields,
		.is_packed = is_packed,
		.has_aligned_field = has_aligned_field(node),
		.alignment = alignment,
		.c_object = c_object,
		.fields = fields
	};

	if (try existing_idx)
	{
		self.tu.structs[existing_idx] = record;
	}
	else
	{
		self.tu.structs.push(record);
	}
}

fn sz? find_struct_index(CTranslationUnit* tu, String c3_name, String c_name) @local
{
	foreach (sz i, &st : tu.structs)
	{
		if (st.c3_name == c3_name || st.c_name == c_name) return i;
	}
	return NOT_FOUND~;
}

<*
 Core EnumDecl parser with explicit name parameter to support typedef wrapping.
 Deduplicates by both C name and sanitized C3 name to avoid enum shadowing.
*>
fn void ParseContext.parse_enum_decl_with_name(&self, Object* node, String c_name)
{
	if (c_name.len == 0)
	{
		return;
	}

	String c3_name = tag_c3_name(self.allocator, c_name, self.options.type_prefix, &self.tu.underscored_tags);

	foreach (&e : self.tu.enums)
	{
		if (e.c3_name == c3_name || e.c_name == c_name)
		{
			return;
		}
	}

	HashSet{String} seen_struct_types;
	seen_struct_types.tinit();
	self.tu.add_type_names(&seen_struct_types, enums: false, typedefs: false);
	c3_name = deduplicate_name(&seen_struct_types, c3_name, self.allocator);

	if (!self.seen_names.add(c_name))
	{
		return;
	}
	self.seen_names.add(c3_name);

	self.target_types.add(c_name);
	self.target_types.add(c3_name);

	EnumBody body = parse_enum_body(self.allocator, node, common_enum_constant_prefix(node));
	self.tu.enums.push({
		.c_name = c_name.copy(self.allocator),
		.c3_name = c3_name,
		.is_constdef = !body.is_sequential,
		.backing_type = body.backing_type,
		.variants = body.variants,
		.comment = ""
	});
}

struct EnumBody
{
	List{CEnumVariant} variants;
	bool is_sequential;
	String backing_type;
}

<*
 Collects EnumConstantDecl children with resolved values.
 Strips `strip_prefix` from variant names.
*>
fn EnumBody parse_enum_body(Allocator allocator, Object* node, String strip_prefix) @local
{
	List{CEnumVariant} variants;
	variants.init(allocator);

	HashSet{String} seen_variant_names;
	seen_variant_names.tinit();

	bool is_sequential = true;
	long expected_val = 0;
	long min_val = 0;
	long max_val = 0;
	bool has_negative = false;

	foreach (child : inner_nodes(node))
	{
		String v_name = child.get_string("name") ?? "";
		if ((child.get_string("kind") ?? "") != "EnumConstantDecl" || v_name.len == 0)
		{
			continue;
		}

		Object*? value_expr = first_inner(child);
		bool has_explicit = @ok(value_expr);
		long val = value_expr.get_string("value").to_long() ?? expected_val;
		if (has_explicit && val != expected_val)
		{
			is_sequential = false;
		}

		String v_c3 = deduplicate_name(&seen_variant_names, v_name[strip_prefix.len..].to_upper_copy(allocator), allocator);

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

	return { variants, is_sequential, backing_type };
}

<*
 Emits a top-level anonymous enum whose constants no typedef has claimed.
 A shared constant-name prefix becomes an inline constdef, otherwise each constant becomes a const.
*>
fn void ParseContext.parse_anonymous_enum(&self, Object* node)
{
	String prefix = common_enum_constant_prefix(node);
	EnumBody body = parse_enum_body(self.allocator, node, prefix);
	if (body.variants.len() == 0 || is_enum_constant_emitted(self.tu, body.variants[0].c_name)) return;

	if (prefix.len == 0)
	{
		foreach (v : body.variants)
		{
			self.tu.constants.push({
				.name = v.c3_name,
				.value = string::format(self.allocator, "%d", v.value),
				.c3_type = body.backing_type
			});
		}
		return;
	}

	HashSet{String} taken_type_names;
	taken_type_names.tinit();
	self.tu.add_type_names(&taken_type_names);

	String type_c_name = prefix.trim("_").to_lower_copy(tmem);
	String c3_name = capitalize_ascii(self.allocator, sanitize_c3_type_name(self.allocator, type_c_name, self.options.type_prefix));
	if (taken_type_names.contains(c3_name)) c3_name = string::format(self.allocator, "%sKind", c3_name);
	self.tu.enums.push({
		.c3_name = deduplicate_name(&taken_type_names, c3_name, self.allocator),
		.is_constdef = true,
		.is_inline = true,
		.backing_type = body.backing_type,
		.variants = body.variants
	});
}

<*
 Longest common prefix of an enum's constant names, cut after a '_' so every name keeps a leading letter.
 Empty when fewer than two constants exist or no such prefix is shared.
*>
fn String common_enum_constant_prefix(Object* node) @local
{
	List{String} names;
	names.tinit();
	foreach (child : inner_nodes(node))
	{
		if ((child.get_string("kind") ?? "") == "EnumConstantDecl") names.push(child.get_string("name") ?? "");
	}
	if (names.len() < 2) return "";

	String prefix = names[0];
	foreach (name : names.array_view()[1..])
	{
		sz n;
		while (n < prefix.len && n < name.len && prefix[n] == name[n]) n++;
		prefix = prefix[:n];
	}

	while (try cut = prefix.rindex_of_char('_'))
	{
		prefix = prefix[:cut + 1];
		if (prefix.trim("_").len == 0) return "";
		if (leaves_valid_constant_names(names.array_view(), prefix)) return prefix;
		prefix = prefix[:cut];
	}
	return "";
}

<*
 Whether removing `prefix` leaves every name starting with a letter.
*>
fn bool leaves_valid_constant_names(String[] names, String prefix) @local
{
	foreach (name : names)
	{
		if (name.len <= prefix.len || !name[prefix.len].is_alpha()) return false;
	}
	return true;
}

fn bool is_enum_constant_emitted(CTranslationUnit* tu, String c_name) @local
{
	foreach (&e : tu.enums)
	{
		foreach (&v : e.variants)
		{
			if (v.c_name == c_name) return true;
		}
	}
	return false;
}

<*
 Gives the unnamed struct or union behind a pointer or array typedef the typedef's name, kept distinct
 by a leading underscore, and returns `qual_type` spelled with that name. Later typedefs of the same
 record reuse the first name.
*>
fn String ParseContext.name_unnamed_record(&self, Object* node, String c_name, String qual_type)
{
	sz? open = qual_type.index_of("(unnamed") ?? qual_type.index_of("(anonymous");
	Object*? record = find_descendant_by_kind(node, "RecordDecl");
	if (catch open, record) return qual_type;
	ParenSpan? span = find_paren_span(qual_type, open);
	if (catch span) return qual_type;

	String tag = self.unnamed_record_tag(resolve_complete_decl(record, &self.anon_records), c_name);
	return string::tformat("%s%s%s", qual_type[:open], tag, qual_type[span.close + 1..]);
}

<*
 Name of an unnamed record: the one it already got, or `c_name`, parsing the record under it.
*>
fn String ParseContext.unnamed_record_tag(&self, Object* record, String c_name)
{
	String id = record.get_string("id") ?? "";
	if (try known = self.unnamed_record_names.get(id)) return known;

	String tag = c_name.copy(self.allocator);
	self.unnamed_record_names.set(id, tag);
	self.tu.underscored_tags.add(tag);
	self.parse_record_decl_with_name(record, tag, "");
	return tag;
}

<*
 Parses a TypedefDecl into either an alias (function pointers) or struct/type alias.
 Resolves anonymous RecordDecl / EnumDecl references by ID.
 Formats function prototypes directly from Clang's FunctionProtoType node.
*>
fn void ParseContext.parse_typedef_decl(&self, Object* node)
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

	foreach (child : inner_nodes(node))
	{
		String child_kind = child.get_string("kind") ?? "";
		if (child_kind != "ElaboratedType" && child_kind != "RecordType" && child_kind != "EnumType")
		{
			continue;
		}

		if (try rec_child = find_descendant_by_kind(child, "RecordDecl", through_typedefs: false))
		{
			Object* full_rec = resolve_complete_decl(rec_child, &self.anon_records);
			String tag_name = full_rec.get_string("name") ?? "";
			RawTypeInfo tinfo = extract_type_info(node);
			bool is_ptr = tinfo.qual_type.contains("*") || tinfo.desugared_type.contains("*");
			if (is_anonymous_tag_name(tag_name) || (tag_name.starts_with("_") && !is_ptr))
			{
				if (tag_name.len > 0) self.seen_names.add(tag_name);
				self.parse_record_decl_with_name(full_rec, c_name, record_c_object(self.allocator, full_rec, c_name));
				return;
			}
		}
		else if (try enum_child = find_descendant_by_kind(child, "EnumDecl", through_typedefs: false))
		{
			Object* full_enum = resolve_complete_decl(enum_child, &self.anon_enums);
			String tag_name = full_enum.get_string("name") ?? "";
			if (is_anonymous_tag_name(tag_name) || tag_name.starts_with("_"))
			{
				if (tag_name.len > 0) self.seen_names.add(tag_name);
				self.parse_enum_decl_with_name(full_enum, c_name);
				return;
			}
		}
	}

	if (is_fundamental_c_type(c_name)) return;

	if (!self.seen_names.add(c_name) && !self.tu.underscored_tags.contains(c_name))
	{
		return;
	}

	self.target_types.add(c_name);

	RawTypeInfo tinfo = extract_type_info(node);
	String qual_type = self.name_unnamed_record(node, c_name, tinfo.qual_type);

	bool is_func_ptr = false;
	String c3_name = sanitize_c3_type_name(self.allocator, c_name, self.options.type_prefix);
	String c3_underlying;

	if (try fpt = find_descendant_by_kind(node, "FunctionProtoType"))
	{
		c3_underlying = self.format_function_proto_from_ast(fpt);
		is_func_ptr = true;
	}
	else
	{
		is_func_ptr = is_c_function_pointer(qual_type);
		if (is_func_ptr)
		{
			c3_underlying = self.parse_function_pointer_type(qual_type);
		}
		else
		{
			c3_underlying = self.map_type(qual_type, tinfo.desugared_type);
		}
	}

	String canonical = tinfo.desugared_type.len > 0 ? tinfo.desugared_type : qual_type;
	if (is_func_ptr && !canonical.contains("(*)") && !canonical.contains("(^)")) self.function_types.add(c_name);

	self.tu.typedefs.push({
		.c_name = c_name.copy(self.allocator),
		.c3_name = c3_name,
		.underlying_c = qual_type.copy(self.allocator),
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
	Object*[] nodes = inner_nodes(root_obj);

	tu.c_long_bits = target_c_long_bits(options.target);
	tu.ms_bitfields = target_uses_ms_bitfields(options.target);
	ParseContext ctx;
	ctx.init(allocator, tu, options);
	defer ctx.free();

	// Pass 1: Index typedefs and records across entire translation unit
	HashMap{String, String} tags_by_c3_name;
	tags_by_c3_name.tinit();
	HashMap{String, String} typedef_tags;
	typedef_tags.tinit();
	foreach (node : nodes)
	{

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
					ctx.external_typedefs.set(td_name.copy(allocator), desugared.copy(allocator));
				}
				bool is_indirect = desugared.contains("*") || desugared.contains("[");
				String named_tag;
				if (try rec_child = find_descendant_by_kind(node, "RecordDecl"))
				{
					String tag = rec_child.get_string("name") ?? "";
					if (!is_indirect) named_tag = tag;
					index_tag_decl(allocator, is_indirect ? tag : td_name, rec_child, &ctx.external_records, &ctx.anon_records);
				}
				else if (try enum_child = find_descendant_by_kind(node, "EnumDecl"))
				{
					String reg_name = is_indirect ? (enum_child.get_string("name") ?? "") : td_name;
					index_tag_decl(allocator, reg_name, enum_child, &ctx.external_enums, &ctx.anon_enums);
				}
				typedef_tags.set(td_name, named_tag);
			}
			continue;
		}

		if (kind == "RecordDecl")
		{
			String tag = node.get_string("name") ?? "";
			if (tag.len > 0 && !is_fundamental_c_type(tag)) tags_by_c3_name.set(sanitize_c3_type_name(tmem, tag, ""), tag);
			index_tag_decl(allocator, tag, node, &ctx.external_records, &ctx.anon_records);
			continue;
		}

		if (kind == "EnumDecl")
		{
			index_tag_decl(allocator, node.get_string("name") ?? "", node, &ctx.external_enums, &ctx.anon_enums);
			continue;
		}
	}

	// A tag that sanitizes to a typedef's name, while the typedef names another type or a pointer,
	// keeps its leading underscore so the typedef's name stays the typedef's.
	typedef_tags.@each(; String td_name, String named_tag)
	{
		if (try tag = tags_by_c3_name.get(sanitize_c3_type_name(tmem, td_name, "")))
		{
			if (tag != named_tag) tu.underscored_tags.add(tag.copy(allocator));
		}
	};

	String current_file = options.header_path;

	List{Object*} anonymous_enums;
	anonymous_enums.init(allocator);

	// Pass 2: Parse declarations from the target header
	foreach (node : nodes)
	{

		if (node.get_bool("isImplicit") ?? false)
		{
			continue;
		}

		String file_loc = extract_node_file(node);
		if (file_loc.len > 0)
		{
			current_file = file_loc;
		}

		if (!is_target_file(current_file, options))
		{
			continue;
		}

		String kind = node.get_string("kind") ?? "";
		switch (kind)
		{
			case "FunctionDecl":
				ctx.parse_function_decl(node);
			case "VarDecl":
				ctx.parse_var_decl(node);
			case "RecordDecl":
				{
					String c_name = node.get_string("name") ?? "";
					if (c_name.len == 0)
					{
						if (try id = node.get_string("id"))
						{
							ctx.anon_records.set(id, node);
						}
					}
					else
					{
						ctx.parse_record_decl_with_name(node, c_name, record_c_object(allocator, node, c_name));
					}
				}
			case "EnumDecl":
				{
					String c_name = node.get_string("name") ?? "";
					if (c_name.len == 0)
					{
						if (try id = node.get_string("id"))
						{
							ctx.anon_enums.set(id, node);
						}
						anonymous_enums.push(node);
					}
					else
					{
						ctx.parse_enum_decl_with_name(node, c_name);
					}
				}
			case "TypedefDecl":
				ctx.parse_typedef_decl(node);
			default:
				break;
		}
	}

	// Pass 3: Synthesize referenced external types
	List{String} ext_worklist;
	ext_worklist.init(allocator);
	ctx.used_external_types.@each(; name)
	{
		ext_worklist.push(name);
	};

	for (sz w_i = 0; w_i < ext_worklist.len(); w_i++)
	{
		String ext_name = ext_worklist.get(w_i);
		if (try rec_node = find_external_tag(ext_name, &ctx.external_records, &ctx.external_typedefs))
		{
			sz prev_count = ctx.used_external_types.count;
			Object* ext_record = resolve_complete_decl(rec_node, &ctx.anon_records);
			ctx.parse_record_decl_with_name(ext_record, ext_name, record_c_object(allocator, ext_record, ext_name));
			if (ctx.used_external_types.count > prev_count)
			{
				ctx.used_external_types.@each(; newly_added)
				{
					if (!ext_worklist.contains(newly_added))
					{
						ext_worklist.push(newly_added);
					}
				};
			}
		}
		else if (try enum_node = find_external_tag(ext_name, &ctx.external_enums, &ctx.external_typedefs))
		{
			ctx.parse_enum_decl_with_name(resolve_complete_decl(enum_node, &ctx.anon_enums), ext_name);
		}
		else if (try desugared_c = ctx.external_typedefs.get(ext_name))
		{
			String c3_name = sanitize_c3_type_name(allocator, ext_name, options.type_prefix);
			String c3_underlying = map_c_type_to_c3(allocator, desugared_c, options.type_prefix, tu);

			if (ctx.seen_names.add(ext_name))
			{
				tu.typedefs.push({
					.c_name = ext_name.copy(allocator),
					.c3_name = c3_name,
					.underlying_c = desugared_c.copy(allocator),
					.underlying_c3 = c3_underlying,
					.is_func_ptr = false,
					.comment = ""
				});
				ctx.target_types.add(ext_name);
			}
		}
	};

	foreach (node : anonymous_enums)
	{
		ctx.parse_anonymous_enum(node);
	}
}
