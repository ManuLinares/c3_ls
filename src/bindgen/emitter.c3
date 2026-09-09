module lsp::bindgen;

import analyzer::core::constants;
import std;

<*
 Emits preprocessor constants as C3 const declarations.
 @param sb : "String buffer accumulator."
 @param tu : "Parsed translation unit."
*>
fn void emit_constants(DString* sb, CTranslationUnit* tu) @local
{
	if (tu.constants.len() == 0)
	{
		return;
	}

	sb.append("// Constants\n");
	foreach (c : tu.constants)
	{
		if (c.c3_type.len > 0)
		{
			sb.appendf("const %s %s = %s;\n", c.c3_type, c.name, c.value);
		}
		else
		{
			sb.appendf("const %s = %s;\n", c.name, c.value);
		}
	}
	sb.append_char('\n');
}

<*
 Emits typedefs and function pointer callbacks as C3 alias declarations.
 Deduplicates declarations to prevent shadowing.
 @param sb : "String buffer accumulator."
 @param tu : "Parsed translation unit."
*>
fn void emit_typedefs(DString* sb, CTranslationUnit* tu) @local
{
	if (tu.typedefs.len() == 0)
	{
		return;
	}

	HashSet{String} seen_aliases;
	seen_aliases.tinit();

	sb.append("// Type Aliases & Callbacks\n");
	foreach (td : tu.typedefs)
	{
		if (td.c3_name == td.underlying_c3 || is_c3_type(td.c3_name) || is_c3_keyword(td.c3_name))
		{
			continue;
		}

		// Break self-referential handle definitions (e.g. alias Hstring = Hstring* -> alias Hstring = void*)
		if (td.underlying_c3.ends_with("*") && extract_base_type_ident(td.underlying_c3) == td.c3_name)
		{
			td.underlying_c3 = "void*";
		}

		if (!seen_aliases.add(td.c3_name))
		{
			continue;
		}

		bool conflicts = false;
		foreach (st : tu.structs)
		{
			if (st.c3_name == td.c3_name)
			{
				conflicts = true;
				break;
			}
		}
		foreach (e : tu.enums)
		{
			if (e.c3_name == td.c3_name)
			{
				conflicts = true;
				break;
			}
		}
		if (conflicts)
		{
			continue;
		}

		sb.appendf("alias %s = %s;\n", td.c3_name, td.underlying_c3);
	}
	sb.append_char('\n');
}

<*
 Emits C enums conforming to vendor guidelines:
 - Sequential 0-started enums emit as 'enum Name { ... }'
 - Non-sequential or bitflag enums emit as 'constdef Name : int { ... }'
 @param sb : "String buffer accumulator."
 @param tu : "Parsed translation unit."
*>
fn void emit_enums(DString* sb, CTranslationUnit* tu) @local
{
	if (tu.enums.len() == 0)
	{
		return;
	}

	HashSet{String} seen_enum_type_names;
	seen_enum_type_names.tinit();

	foreach (e : tu.enums)
	{
		String e_name = deduplicate_name(&seen_enum_type_names, e.c3_name, tmem);

		if (e.variants.len() == 0)
		{
			sb.appendf("typedef %s = int;\n\n", e_name);
			continue;
		}

		HashSet{String} seen_var_names;
		seen_var_names.tinit();

		if (e.is_constdef)
		{
			sb.appendf("constdef %s : %s\n{\n", e_name, e.backing_type);
			for (sz i = 0; i < e.variants.len(); i++)
			{
				CEnumVariant v = e.variants.get(i);
				String vname = deduplicate_name(&seen_var_names, v.c3_name, tmem);

				if (e.backing_type == "uint" && v.value > int::max)
				{
					sb.appendf("\t%s = %du", vname, (uint)v.value);
				}
				else if (e.backing_type == "ulong" && v.value > int::max)
				{
					sb.appendf("\t%s = %dUL", vname, (ulong)v.value);
				}
				else if (e.backing_type == "long" && (v.value > int::max || v.value < int::min))
				{
					sb.appendf("\t%s = %dL", vname, v.value);
				}
				else
				{
					sb.appendf("\t%s = %d", vname, v.value);
				}

				if (i + 1 < e.variants.len())
				{
					sb.append_char(',');
				}
				sb.append_char('\n');
			}
			sb.append("}\n\n");
		}
		else
		{
			sb.appendf("enum %s\n{\n", e_name);
			for (sz i = 0; i < e.variants.len(); i++)
			{
				CEnumVariant v = e.variants.get(i);
				String vname = deduplicate_name(&seen_var_names, v.c3_name, tmem);

				sb.appendf("\t%s", vname);
				if (i + 1 < e.variants.len())
				{
					sb.append_char(',');
				}
				sb.append_char('\n');
			}
			sb.append("}\n\n");
		}
	}
}

fn String extract_base_type_ident(String type_str) @local
{
	String s = type_str.trim();
	if (try idx = s.index_of_char('['))
	{
		s = s[:idx];
	}
	s = s.trim_right("*& \t");
	return s.trim();
}

fn CStruct* find_struct_by_name(CTranslationUnit* tu, String name) @local
{
	for (sz i = 0; i < tu.structs.len(); i++)
	{
		CStruct* st = tu.structs.get_ref(i);
		if (st.c3_name == name || st.c_name == name)
		{
			return st;
		}
	}
	for (sz i = 0; i < tu.typedefs.len(); i++)
	{
		CTypedef* td = tu.typedefs.get_ref(i);
		if (td.c3_name == name)
		{
			String target = extract_base_type_ident(td.underlying_c3);
			return find_struct_by_name(tu, target);
		}
	}
	return null;
}

fn bool struct_has_fam(CTranslationUnit* tu, CStruct* st) @local
{
	if (!st || st.is_union || st.is_opaque || st.fields.len() == 0)
	{
		return false;
	}
	CField last_f = st.fields.get(st.fields.len() - 1);
	if (last_f.c3_type.ends_with("[*]"))
	{
		return true;
	}
	if (!last_f.c3_type.contains("*") && !last_f.c3_type.contains("["))
	{
		String base = extract_base_type_ident(last_f.c3_type);
		CStruct* sub = find_struct_by_name(tu, base);
		if (sub && sub != st)
		{
			return struct_has_fam(tu, sub);
		}
	}
	return false;
}

fn void remove_fam_from_struct(CTranslationUnit* tu, CStruct* st) @local
{
	if (!st || st.is_union || st.is_opaque || st.fields.len() == 0)
	{
		return;
	}
	CField last_f = st.fields.get(st.fields.len() - 1);
	if (last_f.c3_type.ends_with("[*]"))
	{
		(void)st.fields.pop();
		return;
	}
	if (!last_f.c3_type.contains("*") && !last_f.c3_type.contains("["))
	{
		String base = extract_base_type_ident(last_f.c3_type);
		CStruct* sub = find_struct_by_name(tu, base);
		if (sub && sub != st)
		{
			remove_fam_from_struct(tu, sub);
		}
	}
}

<*
 Prevents C3 compile errors by sanitizing arrays of structs containing flexible array members.
*>
fn void sanitize_fam_arrays(Allocator allocator, CTranslationUnit* tu) @local
{
	for (sz i = 0; i < tu.structs.len(); i++)
	{
		CStruct* st = tu.structs.get_ref(i);
		if (st.is_union || st.is_opaque)
		{
			continue;
		}

		sz non_fam_count = 0;
		for (sz j = 0; j < st.fields.len(); j++)
		{
			if (!st.fields.get(j).c3_type.ends_with("[*]"))
			{
				non_fam_count++;
			}
		}

		if (non_fam_count == 0)
		{
			st.is_opaque = true;
			st.fields.clear();
			continue;
		}

		if (st.fields.len() <= 1)
		{
			continue;
		}

		sz write_idx = 0;
		sz total_fields = st.fields.len();
		for (sz j = 0; j < total_fields; j++)
		{
			CField f = st.fields.get(j);
			bool is_fam = f.c3_type.ends_with("[*]");
			bool is_last = (j + 1 == total_fields);

			if (is_fam && !is_last)
			{
				continue;
			}

			if (write_idx != j)
			{
				st.fields.set(write_idx, f);
			}
			write_idx++;
		}

		while (st.fields.len() > write_idx)
		{
			(void)st.fields.pop();
		}
	}

	bool fam_modified = true;
	while (fam_modified)
	{
		fam_modified = false;
		for (sz i = 0; i < tu.structs.len(); i++)
		{
			CStruct* st = tu.structs.get_ref(i);
			if (st.is_union || st.is_opaque || st.fields.len() <= 1)
			{
				continue;
			}

			sz total_fields = st.fields.len();
			for (sz j = 0; j + 1 < total_fields; j++)
			{
				CField f = st.fields.get(j);
				if (!f.c3_type.contains("*") && !f.c3_type.contains("["))
				{
					String base = extract_base_type_ident(f.c3_type);
					CStruct* sub_st = find_struct_by_name(tu, base);
					if (sub_st && sub_st != st && struct_has_fam(tu, sub_st))
					{
						remove_fam_from_struct(tu, sub_st);
						fam_modified = true;
					}
				}
			}
		}
	}

	HashSet{String} fam_structs;
	fam_structs.tinit();

	bool changed = true;
	while (changed)
	{
		changed = false;
		foreach (st : tu.structs)
		{
			if (st.is_union || fam_structs.contains(st.c3_name))
			{
				continue;
			}
			foreach (f : st.fields)
			{
				if (f.c3_type.ends_with("[*]"))
				{
					fam_structs.add(st.c3_name);
					changed = true;
					break;
				}
				String base = extract_base_type_ident(f.c3_type);
				if (!f.c3_type.contains("*") && !f.c3_type.contains("[") && fam_structs.contains(base))
				{
					fam_structs.add(st.c3_name);
					changed = true;
					break;
				}
			}
		}
		foreach (td : tu.typedefs)
		{
			if (!td.is_func_ptr && fam_structs.contains(td.underlying_c3))
			{
				if (fam_structs.add(td.c3_name))
				{
					changed = true;
				}
			}
		}
	}

	if (fam_structs.len() == 0)
	{
		return;
	}

	for (sz i = 0; i < tu.structs.len(); i++)
	{
		CStruct* st = tu.structs.get_ref(i);
		for (sz j = 0; j < st.fields.len(); j++)
		{
			CField* f = st.fields.get_ref(j);
			String base = extract_base_type_ident(f.c3_type);
			if (fam_structs.contains(base))
			{
				if (try open_b = f.c3_type.index_of_char('['))
				{
					String before_bracket = f.c3_type[:open_b];
					if (!before_bracket.ends_with("*"))
					{
						if (f.c3_type.ends_with("[*]"))
						{
							f.c3_type = "char[*]";
						}
						else
						{
							f.c3_type = "void*";
						}
					}
				}
			}
		}
	}

	for (sz i = 0; i < tu.typedefs.len(); i++)
	{
		CTypedef* td = tu.typedefs.get_ref(i);
		String base = extract_base_type_ident(td.underlying_c3);
		if (fam_structs.contains(base))
		{
			if (try open_b = td.underlying_c3.index_of_char('['))
			{
				String before_bracket = td.underlying_c3[:open_b];
				if (!before_bracket.ends_with("*"))
				{
					if (td.underlying_c3.ends_with("[*]"))
					{
						td.underlying_c3 = "char[*]";
					}
					else
					{
						td.underlying_c3 = "void*";
					}
				}
			}
		}
	}

	for (sz i = 0; i < tu.functions.len(); i++)
	{
		CFunction* fn_decl = tu.functions.get_ref(i);
		for (sz j = 0; j < fn_decl.params.len(); j++)
		{
			CParam* p = fn_decl.params.get_ref(j);
			String base = extract_base_type_ident(p.c3_type);
			if (fam_structs.contains(base))
			{
				if (try open_b = p.c3_type.index_of_char('['))
				{
					String before_bracket = p.c3_type[:open_b];
					if (!before_bracket.ends_with("*"))
					{
						p.c3_type = string::format(allocator, "%s*", base);
					}
				}
			}
		}
	}
}

fn void record_missing_type(HashSet{String}* known, List{String}* missing, String type_str) @local
{
	String t = extract_base_type_ident(type_str);
	if (t.len == 0 || t.len > MAX_IDENTIFIER_LEN || t[0] < 'A' || t[0] > 'Z' || t.contains("(") || t.contains(" "))
	{
		return;
	}
	if (!known.contains(t) && known.add(t))
	{
		missing.push(t);
	}
}

<*
 Emits C structs and unions.
 Deduplicates field names and generates opaque declarations for missing types.
*>
fn void emit_structs(DString* sb, CTranslationUnit* tu) @local
{
	HashSet{String} known_types;
	known_types.tinit();
	foreach (p : constants::Primitives::values)
	{
		known_types.add(p);
	}
	const String[*] EXTRA_BUILTINS = {
		"String", "ZString", "CVaList", "CLong", "CULong", "CChar", "CSChar",
		"CUChar", "CShort", "CUShort", "CInt", "CUInt", "CLongLong", "CULongLong", "CBool"
	};
	foreach (b : EXTRA_BUILTINS)
	{
		known_types.add(b);
	}
	foreach (td : tu.typedefs)
	{
		known_types.add(td.c3_name);
	}
	foreach (e : tu.enums)
	{
		known_types.add(e.c3_name);
	}
	foreach (st : tu.structs)
	{
		known_types.add(st.c3_name);
	}

	List{String} missing_structs;
	missing_structs.tinit();

	foreach (st : tu.structs)
	{
		foreach (f : st.fields)
		{
			record_missing_type(&known_types, &missing_structs, f.c3_type);
		}
	}

	foreach (fn_decl : tu.functions)
	{
		record_missing_type(&known_types, &missing_structs, fn_decl.ret_type_c3);
		foreach (p : fn_decl.params)
		{
			record_missing_type(&known_types, &missing_structs, p.c3_type);
		}
	}

	foreach (td : tu.typedefs)
	{
		if (td.is_func_ptr)
		{
			sz open_p = td.underlying_c3.index_of_char('(') ?? 0;
			sz close_p = td.underlying_c3.rindex_of_char(')') ?? 0;

			if (open_p > 3)
			{
				String ret_part = td.underlying_c3[3 : open_p - 3].trim();
				record_missing_type(&known_types, &missing_structs, ret_part);
			}

			if (close_p > open_p + 1)
			{
				String params_part = td.underlying_c3[open_p + 1 : close_p - (open_p + 1)];
				String[] p_tokens = params_part.tsplit(",");
				foreach (tok : p_tokens)
				{
					record_missing_type(&known_types, &missing_structs, tok.trim());
				}
			}
		}
		else
		{
			record_missing_type(&known_types, &missing_structs, td.underlying_c3);
		}
	}

	HashSet{String} seen_struct_names;
	seen_struct_names.tinit();
	foreach (e : tu.enums)
	{
		seen_struct_names.add(e.c3_name);
	}
	foreach (td : tu.typedefs)
	{
		seen_struct_names.add(td.c3_name);
	}

	foreach (ms : missing_structs)
	{
		if (seen_struct_names.add(ms))
		{
			sb.appendf("struct %s { void* _unused; }\n\n", ms);
		}
	}

	if (tu.structs.len() == 0)
	{
		return;
	}

	foreach (st : tu.structs)
	{
		String st_name = deduplicate_name(&seen_struct_names, st.c3_name, tmem);

		if (st.is_opaque || st.fields.len() == 0)
		{
			sb.appendf("struct %s { void* _unused; }\n\n", st_name);
			continue;
		}

		String kind_kw = st.is_union ? "union" : "struct";
		sb.appendf("%s %s\n{\n", kind_kw, st_name);

		HashSet{String} seen_field_names;
		seen_field_names.tinit();

		foreach (f : st.fields)
		{
			String fname = deduplicate_name(&seen_field_names, f.c3_name, tmem);

			// Break recursive self-containment by value
			String ftype = f.c3_type;
			if (ftype == st.c3_name)
			{
				ftype = "void*";
			}

			sb.appendf("\t%s %s;\n", ftype, fname);
		}

		sb.append("}\n\n");
	}
}

<*
 Emits C functions as C3 extern declarations with @cname and @noalias attributes.
 @param sb : "String buffer accumulator."
 @param tu : "Parsed translation unit."
*>
fn void emit_functions(DString* sb, CTranslationUnit* tu) @local
{
	if (tu.functions.len() == 0)
	{
		return;
	}

	HashSet{String} seen_fn_names;
	seen_fn_names.tinit();

	sb.append("// Functions\n");
	foreach (fn_decl : tu.functions)
	{
		String fname = deduplicate_name(&seen_fn_names, fn_decl.c3_name, tmem);

		sb.appendf("extern fn %s %s(", fn_decl.ret_type_c3, fname);

		HashSet{String} seen_p_names;
		seen_p_names.tinit();

		for (sz i = 0; i < fn_decl.params.len(); i++)
		{
			CParam p = fn_decl.params.get(i);
			String pname = deduplicate_name(&seen_p_names, p.name, tmem);

			if (p.is_noalias && (p.c3_type.ends_with("*") || p.c3_type.ends_with("]")))
			{
				sb.appendf("%s %s @noalias", p.c3_type, pname);
			}
			else
			{
				sb.appendf("%s %s", p.c3_type, pname);
			}

			if (i + 1 < fn_decl.params.len())
			{
				sb.append(", ");
			}
		}

		if (fn_decl.is_variadic)
		{
			if (fn_decl.params.len() > 0)
			{
				sb.append(", ...");
			}
			else
			{
				sb.append("...");
			}
		}

		sb.appendf(") @cname(\"%s\");\n", fn_decl.c_name);
	}
	sb.append_char('\n');
}

<*
 Formats the complete CTranslationUnit into a C3 binding source string.
 Sanitizes the module header identifier.
 @param allocator : "Allocator used for the returned string."
 @param tu        : "Parsed translation unit containing all declarations."
 @param options   : "Bindgen configuration options."
 @return          "Generated C3 binding code."
*>
fn String emit_c3_bindings(Allocator allocator, CTranslationUnit* tu, BindgenOptions options)
{
	sanitize_fam_arrays(allocator, tu);

	DString sb;
	sb.init(allocator);

	String mod_name = sanitize_module_name(allocator, options.module_name.len > 0 ? options.module_name : "c_lib");
	sb.appendf("module %s;\n\n", mod_name);

	emit_constants(&sb, tu);
	emit_typedefs(&sb, tu);
	emit_enums(&sb, tu);
	emit_structs(&sb, tu);
	emit_functions(&sb, tu);

	return sb.str_view().copy(allocator);
}