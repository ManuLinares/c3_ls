module analyzer::sema::query;
import analyzer, std::collections::list, std::collections::map, std::io, std::io::path, std::sort;

struct LocalSearchContext
{
	AnalyzerContext* context;
	SourceFile* sf;
	String name;
	Node* found_decl;
	String found_type;
}

fn ChildVisitResult find_local_decl_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	LocalSearchContext* ctx = (LocalSearchContext*)user_data;

	switch (c.kind)
	{
		case VAR_DECL:
			{
				VarDecl* vd = c.as(VarDecl);
				if (vd.name && vd.name.text == ctx.name)
				{
					ctx.found_decl = c;
					if (vd.type)
					{
						ctx.found_type = cursor::spelling(vd.type, tmem);
					}
					return BREAK;
				}
			}
		case TRY_EXPR:
			{
				TryExpr* te = c.as(TryExpr);
				if (!te.variable || te.variable.kind != IDENT_EXPR) return RECURSE;
				IdentExpr* ie = te.variable.as(IdentExpr);
				if (!ie.ident || ie.ident.text != ctx.name) return RECURSE;
				ctx.found_decl = c;
				if (te.type)
				{
					ctx.found_type = cursor::spelling(te.type, tmem);
				}
				else if (te.init)
				{
					String itype = type_of(ctx.context, ctx.sf, te.init);
					ctx.found_type = itype.trim_right("?*& \t");
				}
				return BREAK;
			}
		case CATCH_EXPR:
			{
				CatchExpr* ce = c.as(CatchExpr);
				if (!ce.variable || ce.variable.kind != IDENT_EXPR) return RECURSE;
				IdentExpr* ie = ce.variable.as(IdentExpr);
				if (!ie.ident || ie.ident.text != ctx.name) return RECURSE;
				ctx.found_decl = c;
				ctx.found_type = ce.type ? (cursor::spelling(ce.type, tmem) ?: "fault") : "fault";
				return BREAK;
			}
		case FOREACH_STMT:
			{
				ForeachStmt* fst = c.as(ForeachStmt);
				foreach (binding : (Node*[]){ fst.index, fst.variable })
				{
					if (!binding || binding.kind != VAR_DECL || !binding.as(VarDecl).name || binding.as(VarDecl).name.text != ctx.name) continue;
					ctx.found_decl = binding;
					ctx.found_type = foreach_binding_type(ctx.context, ctx.sf, fst, binding);
					return BREAK;
				}
			}
		default:
			break;
	}

	return RECURSE;
}

<*
 Type of `binding`, the index or value variable of `fst`: as written, else
 sz for the index and the element type for the value, a pointer to it when
 bound by reference.
*>
fn String foreach_binding_type(AnalyzerContext* context, SourceFile* sf, ForeachStmt* fst, Node* binding)
{
	VarDecl* vd = binding.as(VarDecl);
	if (vd.type) return cursor::instance_name(vd.type);
	if (binding == fst.index) return "sz";
	if (!fst.enumeration) return "";
	String element = element_type(context, sf, type_of(context, sf, fst.enumeration), fst.enumeration.range.start);
	return fst.value_by_ref && element.len ? string::tformat("%s*", element) : element;
}

fn Node* find_local_decl_in_file(SourceFile* sf, String name, String* out_type = null, AnalyzerContext* context = null, Location loc = { -1, -1 })
{
	if (!sf || name.len == 0) return null;
	LocalSearchContext loc_search = {.context = context,.sf = sf,.name = name,.found_decl = null,.found_type = "" };
	if (loc.line >= 0)
	{
		foreach (stmt : sf.ast.statements)
		{
			if (stmt && stmt.range.contains(loc))
			{
				cursor::visit(stmt, null, {.on_enter = &find_local_decl_callback }, &loc_search);
				if (loc_search.found_decl)
				{
					if (out_type)
					{
						*out_type = loc_search.found_type;
					}
					return loc_search.found_decl;
				}
				break;
			}
		}
	}

	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		cursor::visit(stmt, null, {.on_enter = &find_local_decl_callback }, &loc_search);
		if (loc_search.found_decl)
		{
			if (out_type)
			{
				*out_type = loc_search.found_type;
			}
			return loc_search.found_decl;
		}
	}
	return null;
}

fn bool is_vector_type(String type_name)
{
	if (type_name.len == 0) return false;
	return type_name.contains("[<") && type_name.contains(">]");
}

fn String get_source_file_module_name(SourceFile* sf)
{
	if (!sf) return "";
	if (sf.ast.module_decls.len())
	{
		String name = module_decl_name(sf.ast.statements[sf.ast.module_decls[0]]);
		if (name.len) return name;
	}
	return file_stem_from_path(sf.path);
}

fn String module_decl_name(Node* stmt) @local
{
	ModuleDecl* md = stmt.as(ModuleDecl);
	return md.path && md.path.kind == PATH_EXPR && md.path.as(PathExpr).path ? md.path.as(PathExpr).path.text : "";
}

<*
 Index into `sf.ast.module_decls` of the last module section starting on or
 before the line of `loc`, or -1. A negative line means the end of the file.
*>
fn sz section_at(SourceFile* sf, Location loc) @local
{
	sz[] decls = sf.ast.module_decls.array_view();
	if (loc.line < 0) return decls.len - 1;
	sz low = 0;
	sz high = decls.len;
	while (low < high)
	{
		sz mid = (low + high) / 2;
		if (sf.ast.statements[decls[mid]].range.start.line <= loc.line)
		{
			low = mid + 1;
		}
		else
		{
			high = mid;
		}
	}
	return low - 1;
}

fn String get_module_name_at_location(SourceFile* sf, Location loc)
{
	if (!sf) return "";
	for (sz i = section_at(sf, loc); i >= 0; i--)
	{
		String name = module_decl_name(sf.ast.statements[sf.ast.module_decls[i]]);
		if (name.len) return name;
	}
	return get_source_file_module_name(sf);
}

fn void get_module_section_stmt_range(SourceFile* sf, Location loc, sz* out_start, sz* out_end)
{
	*out_start = 0;
	*out_end = sf ? sf.ast.statements.len() : 0;
	if (!sf || loc.line < 0) return;
	sz[] decls = sf.ast.module_decls.array_view();
	sz section = section_at(sf, loc);
	if (section >= 0) *out_start = decls[section];
	if (section + 1 < decls.len) *out_end = decls[section + 1];
}

<*
 Whether importing `imp_path` makes `target_mod` visible: the module itself and,
 unless the import is `@norecurse`, its sub-modules and parent modules.
*>
fn bool import_reaches(String imp_path, bool is_recursive, String target_mod) @local
{
	if (imp_path == target_mod) return true;
	if (!is_recursive) return false;
	return module_is_within(target_mod, imp_path) || module_is_within(imp_path, target_mod);
}

fn bool module_is_within(String mod, String ancestor) @local
{
	return mod.len > ancestor.len + 2 && mod.starts_with(ancestor) && mod[ancestor.len:2] == "::";
}

<*
 Whether an import in the module section at `loc` reaches `target_mod`, and is
 `@public` when `require_public` is set.
*>
fn bool section_imports_reach(SourceFile* sf, Location loc, String target_mod, bool require_public) @local
{
	sz start_idx = 0;
	sz end_idx = 0;
	get_module_section_stmt_range(sf, loc, &start_idx, &end_idx);

	for (sz i = start_idx; i < end_idx; i++)
	{
		Node* stmt = sf.ast.statements.get(i);
		if (!stmt || stmt.kind != IMPORT_DECL) continue;
		ImportDecl* imp = stmt.as(ImportDecl);
		bool stmt_is_public = cursor::has_attribute((Node*)imp, PUBLIC, null);
		bool stmt_is_recursive = !cursor::has_attribute((Node*)imp, NORECURSE, null);

		foreach (p : imp.paths)
		{
			if (!p || p.kind != PATH_EXPR) continue;
			PathExpr* pe = p.as(PathExpr);
			String imp_path = pe.path ? pe.path.text.strip_suffix("::") : "";
			if (imp_path.len == 0) continue;
			if (require_public && !stmt_is_public && !cursor::has_attribute(p, PUBLIC, null)) continue;
			if (import_reaches(imp_path, stmt_is_recursive && !cursor::has_attribute(p, NORECURSE, null), target_mod)) return true;
		}
	}
	return false;
}

fn bool is_imported_as_public_at(SourceFile* sf, Location loc, String target_mod)
{
	if (!sf || target_mod.len == 0) return false;
	return section_imports_reach(sf, loc, target_mod, require_public: true);
}

fn List{String} get_imported_modules_at_location(SourceFile* sf, Location loc)
{
	List{String} list;
	list.tinit();
	if (!sf) return list;

	list.push("std::core");
	list.push("std::core::builtin");
	list.push("std::core::mem");
	list.push("std::core::string");
	list.push("std::core::types");

	sz start_idx = 0;
	sz end_idx = 0;
	get_module_section_stmt_range(sf, loc, &start_idx, &end_idx);

	for (sz i = start_idx; i < end_idx; i++)
	{
		Node* stmt = sf.ast.statements.get(i);
		if (!stmt || stmt.kind != IMPORT_DECL) continue;
		ImportDecl* imp = stmt.as(ImportDecl);
		foreach (p : imp.paths)
		{
			if (!p || p.kind != PATH_EXPR) continue;
			PathExpr* pe = p.as(PathExpr);
			String imp_path = pe.path ? pe.path.text.strip_suffix("::") : "";
			if (imp_path.len > 0)
			{
				list.push(imp_path);
			}
		}
	}
	return list;
}

fn List{String} get_source_file_imported_modules(SourceFile* sf)
{
	return get_imported_modules_at_location(sf, { -1, -1 });
}

fn bool is_module_visible_at(AnalyzerContext* context, SourceFile* sf, Location loc, String target_mod)
{
	if (!sf || target_mod.len == 0) return false;

	String sf_mod = loc.line >= 0 ? get_module_name_at_location(sf, loc) : get_source_file_module_name(sf);
	if (sf_mod.len > 0 && sf_mod == target_mod) return true;

	if (target_mod == "std::core" || target_mod.starts_with("std::core::")) return true;

	if (module_is_within(sf_mod, target_mod) || module_is_within(target_mod, sf_mod)) return true;

	return section_imports_reach(sf, loc, target_mod, require_public: false);
}

fn bool is_symbol_accessible_at(AnalyzerContext* context, SourceFile* sf, Location loc, Node* target_node, String target_mod)
{
	if (!target_node || !sf) return false;

	switch (target_node.visibility)
	{
		case PUBLIC:
			return true;

		case LOCAL:
			if (!sf.contains_node(target_node)) return false;
			if (loc.line < 0) return true;
			sz start_idx = 0;
			sz end_idx = 0;
			get_module_section_stmt_range(sf, loc, &start_idx, &end_idx);
			for (sz i = start_idx; i < end_idx; i++)
			{
				Node* sec_stmt = sf.ast.statements.get(i);
				if (!sec_stmt) continue;
				if (sec_stmt == target_node || sec_stmt.range.contains_range(target_node.range))
				{
					return true;
				}
			}
			return false;

		case PRIVATE:
			String caller_mod = loc.line >= 0 ? get_module_name_at_location(sf, loc) : get_source_file_module_name(sf);
			if (caller_mod.len > 0 && target_mod.len > 0 && caller_mod == target_mod) return true;
			if (caller_mod.len == 0 && target_mod.len == 0 && sf.contains_node(target_node)) return true;
			if (is_imported_as_public_at(sf, loc, target_mod)) return true;
			return false;
	}
}

fn Module* resolve_module_for_prefix(AnalyzerContext* context, SourceFile* sf, Location loc, String mod_prefix)
{
	if (!context || mod_prefix.len == 0) return null;

	if (Module* m = context.modules.get(mod_prefix) ?? null)
	{
		return m;
	}

	String caller_mod = sf ? (loc.line >= 0 ? get_module_name_at_location(sf, loc) : get_source_file_module_name(sf)) : "";

	if (sf)
	{
		sz start_idx = 0;
		sz end_idx = 0;
		get_module_section_stmt_range(sf, loc, &start_idx, &end_idx);
		for (sz i = start_idx; i < end_idx; i++)
		{
			Node* stmt = sf.ast.statements.get(i);
			if (stmt && stmt.kind == ALIAS_DECL)
			{
				AliasDecl* ad = stmt.as(AliasDecl);
				if (ad.alias_kind == MODULE_ALIAS && ad.name && ad.name.text == mod_prefix && ad.target && ad.target.kind == PATH_EXPR)
				{
					PathExpr* pe = ad.target.as(PathExpr);
					String target_path = pe.path ? pe.path.text.strip_suffix("::") : "";
					if (Module* target_mod = context.modules.get(target_path) ?? null)
					{
						return target_mod;
					}
				}
			}
		}
	}

	if (sf)
	{
		List{String} imports = get_imported_modules_at_location(sf, loc);
		String suffix = string::tformat("::%s", mod_prefix);
		foreach (imp : imports)
		{
			if (imp == mod_prefix || imp.ends_with(suffix))
			{
				if (Module* imp_mod = context.modules.get(imp) ?? null)
				{
					return imp_mod;
				}
			}
		}
	}

	if (caller_mod.len > 0)
	{
		String submod_name = string::tformat("%s::%s", caller_mod, mod_prefix);
		if (Module* submod = context.modules.get(submod_name) ?? null)
		{
			return submod;
		}
	}

	if (sf)
	{
		List{String} imports = get_imported_modules_at_location(sf, loc);
		String suffix = string::tformat("::%s", mod_prefix);
		foreach (imp : imports)
		{
			String imp_sub = string::tformat("%s::%s", imp, mod_prefix);
			if (Module* submod = context.modules.get(imp_sub) ?? null)
			{
				return submod;
			}

			String imp_prefix = string::tformat("%s::", imp);
			context.modules.@each(; mname, m)
			{
				if (mname.starts_with(imp_prefix) && (mname == mod_prefix || mname.ends_with(suffix)))
				{
					return m;
				}
			};
		}
	}

	if (caller_mod.len > 0)
	{
		if (try dot_idx = caller_mod.index_of("::"))
		{
			String top_mod = caller_mod[:dot_idx];
			String top_sub = string::tformat("%s::%s", top_mod, mod_prefix);
			if (Module* top_sub_mod = context.modules.get(top_sub) ?? null)
			{
				return top_sub_mod;
			}
		}
	}

	String suffix = string::tformat("::%s", mod_prefix);
	Module* fallback_mod = null;
	context.modules.@each(; mname, m)
	{
		if (!fallback_mod && (mname == mod_prefix || mname.ends_with(suffix)))
		{
			fallback_mod = m;
		}
	};
	return fallback_mod;
}

fn Node* find_type_node_in_context(AnalyzerContext* context, SourceFile* sf, String type_name, Location loc = { -1, -1 })
{
	if (!context || type_name.len == 0) return null;

	String clean_type = type_name.trim_right("*&? \t");
	if (try idx = clean_type.index_of_char('{'))
	{
		clean_type = clean_type[:idx].trim();
	}
	clean_type = clean_type.trim_right("*&? \t");

	if (constants::is_primitive(clean_type)) return null;

	if (try dot_idx = clean_type.rindex_of_char('.'))
	{
		String parent_type = clean_type[:dot_idx].trim();
		String child_name = clean_type[dot_idx + 1..].trim();
		Node* parent_node = find_type_node_in_context(context, sf, parent_type, loc);
		if (parent_node && parent_node.kind == STRUCT_DECL)
		{
			foreach (f : parent_node.as(StructDecl).fields)
			{
				if (f && f.kind == STRUCT_DECL && f.as(StructDecl).name && f.as(StructDecl).name.text == child_name)
				{
					return f;
				}
			}
		}
		return null;
	}

	if (context.registry)
	{
		if (clean_type.contains("::"))
		{
			TypeInfo* curr = context.registry.types.get(clean_type) ?? null;
			while (curr != null)
			{
				if (curr.node && (!sf || is_symbol_accessible_at(context, sf, loc, curr.node, curr.mod)))
				{
					return curr.node;
				}
				curr = curr.next;
			}
		}

		String caller_mod = sf ? (loc.line >= 0 ? get_module_name_at_location(sf, loc) : get_source_file_module_name(sf)) : "";
		if (caller_mod.len > 0)
		{
			String local_qname = string::tformat("%s::%s", caller_mod, clean_type);
			TypeInfo* curr = context.registry.types.get(local_qname) ?? null;
			while (curr != null)
			{
				if (curr.node && (!sf || is_symbol_accessible_at(context, sf, loc, curr.node, curr.mod)))
				{
					return curr.node;
				}
				curr = curr.next;
			}
		}

		if (sf)
		{
			List{String} imports = loc.line >= 0 ? get_imported_modules_at_location(sf, loc) : get_source_file_imported_modules(sf);
			foreach (imp : imports)
			{
				String imp_qname = string::tformat("%s::%s", imp, clean_type);
				TypeInfo* curr = context.registry.types.get(imp_qname) ?? null;
				while (curr != null)
				{
					if (curr.node && is_symbol_accessible_at(context, sf, loc, curr.node, curr.mod))
					{
						return curr.node;
					}
					curr = curr.next;
				}
			}
		}

		String suffix = string::tformat("::%s", clean_type);
		TypeInfo* matched = null;
		context.registry.types.@each(; qname, tinfo)
		{
			if (!matched && (qname == clean_type || qname.ends_with(suffix)))
			{
				TypeInfo* curr = tinfo;
				while (curr != null)
				{
					if (!sf || (is_module_visible_at(context, sf, loc, curr.mod) && is_symbol_accessible_at(context, sf, loc, curr.node, curr.mod)))
					{
						matched = curr;
						break;
					}
					curr = curr.next;
				}
			}
		};
		if (matched && matched.node) return matched.node;
	}

	if (context)
	{
		context.modules.@each(; mod_name, mod)
		{
			if (mod && (!sf || is_module_visible_at(context, sf, loc, mod_name)))
			{
				foreach (n : mod.nodes)
				{
					if (!n || n.kind == ERROR) continue;

					switch (n.kind)
					{
						case STRUCT_DECL:
							if (n.as(StructDecl).name && n.as(StructDecl).name.text == clean_type)
							{
								if (!sf || is_symbol_accessible_at(context, sf, loc, n, mod_name)) return n;
							}
						case ENUM_DECL:
							if (n.as(EnumDecl).name && n.as(EnumDecl).name.text == clean_type)
							{
								if (!sf || is_symbol_accessible_at(context, sf, loc, n, mod_name)) return n;
							}
						case TYPEDEF_DECL:
							if (n.as(TypedefDecl).name && n.as(TypedefDecl).name.text == clean_type)
							{
								if (!sf || is_symbol_accessible_at(context, sf, loc, n, mod_name)) return n;
							}
						case ALIAS_DECL:
							if (n.as(AliasDecl).name && n.as(AliasDecl).name.text == clean_type)
							{
								if (!sf || is_symbol_accessible_at(context, sf, loc, n, mod_name)) return n;
							}
						default:
							break;
					}
				}
			}
		};
	}

	return null;
}

fn bool module_paths_match(String p1, String p2) @local
{
	if (p1 == p2) return true;
	if (p1.len > p2.len)
	{
		sz diff = p1.len - p2.len;
		if (diff >= 2 && p1.ends_with(p2) && p1[diff - 2] == ':' && p1[diff - 1] == ':') return true;
	}
	else if (p2.len > p1.len)
	{
		sz diff = p2.len - p1.len;
		if (diff >= 2 && p2.ends_with(p1) && p2[diff - 2] == ':' && p2[diff - 1] == ':') return true;
	}
	return false;
}

fn bool is_matching_associated_type(Node* assoc_type_node, String clean_type, String type_name = "")
{
	if (!assoc_type_node) return false;

	String target_clean = clean_type.trim_right("*&? \t");
	if (try b_idx = target_clean.index_of_char('{'))
	{
		target_clean = target_clean[:b_idx].trim();
	}
	target_clean = target_clean.trim_right("*&? \t");

	String target_path = "";
	String target_base = target_clean;
	if (try sc_idx = target_clean.rindex_of("::"))
	{
		target_path = target_clean[:sc_idx];
		target_base = target_clean[sc_idx + 2..];
	}

	String assoc_raw = "";
	String assoc_path = "";

	if (assoc_type_node.kind == TYPE_EXPR)
	{
		TypeExpr* te = assoc_type_node.as(TypeExpr);
		if (te.type_kind == TYPE_IDENTIFIER)
		{
			assoc_raw = te.unresolved.name ? te.unresolved.name.text : "";
			if (te.unresolved.path && te.unresolved.path.kind == PATH_EXPR)
			{
				PathExpr* pe = te.unresolved.path.as(PathExpr);
				if (pe.path)
				{
					assoc_path = pe.path.text.strip_suffix("::");
				}
			}
		}
	}

	if (assoc_raw.len == 0)
	{
		assoc_raw = cursor::raw_type_identifier(assoc_type_node) ?? "";
		assoc_raw = assoc_raw.trim_right("*&? \t");
	}

	if (assoc_raw.len > 0 && target_base.len > 0 && assoc_raw == target_base)
	{
		if (assoc_path.len == 0 || target_path.len == 0) return true;
		return module_paths_match(assoc_path, target_path);
	}

	if (type_name.len > 0 && type_name != clean_type)
	{
		if (is_matching_associated_type(assoc_type_node, type_name)) return true;
	}

	if (is_vector_type(target_clean))
	{
		String assoc_spell = cursor::spelling(assoc_type_node, tmem).trim_right("*&? \t");
		if (is_vector_type(assoc_spell) || is_vector_type(assoc_raw)) return true;
	}

	return false;
}

fn Node* check_fn_list_for_function(AnalyzerContext* context, FunctionInfo* head, SourceFile* sf = null, Location loc = { -1, -1 })
{
	FunctionInfo* curr = head;
	while (curr != null)
	{
		if (curr.node && curr.node.kind == FN_DECL)
		{
			FnDecl* fd = curr.node.as(FnDecl);
			if (fd.associated_type == null)
			{
				if (!sf || is_symbol_accessible_at(context, sf, loc, curr.node, curr.mod))
				{
					return curr.node;
				}
			}
		}
		curr = curr.next;
	}
	return null;
}

fn Node* check_macro_list_for_macro(AnalyzerContext* context, MacroInfo* head, SourceFile* sf = null, Location loc = { -1, -1 })
{
	MacroInfo* curr = head;
	while (curr != null)
	{
		if (curr.node && curr.node.kind == MACRO_DECL)
		{
			MacroDecl* md = curr.node.as(MacroDecl);
			if (!@ok(md.associated_type.get()))
			{
				if (!sf || is_symbol_accessible_at(context, sf, loc, curr.node, curr.mod))
				{
					return curr.node;
				}
			}
		}
		curr = curr.next;
	}
	return null;
}

fn Node* find_attrmacro_in_scope(AnalyzerContext* context, SourceFile* sf, String name, String caller_mod = "", Location loc = { -1, -1 })
{
	if (!context || !context.registry || name.len == 0) return null;

	if (caller_mod.len > 0)
	{
		String local_qname = string::tformat("%s::%s", caller_mod, name);
		AttrdefInfo* curr = context.registry.attrmacros.get(local_qname) ?? null;
		while (curr != null)
		{
			if (curr.node && (!sf || is_symbol_accessible_at(context, sf, loc, curr.node, curr.mod)))
			{
				return curr.node;
			}
			curr = curr.next;
		}
	}

	AttrdefInfo* direct = context.registry.attrmacros.get(name) ?? null;
	while (direct != null)
	{
		if (direct.node && (!sf || is_symbol_accessible_at(context, sf, loc, direct.node, direct.mod)))
		{
			return direct.node;
		}
		direct = direct.next;
	}

	if (sf)
	{
		List{String} imports = loc.line >= 0 ? get_imported_modules_at_location(sf, loc) : get_source_file_imported_modules(sf);
		foreach (imp : imports)
		{
			String imp_qname = string::tformat("%s::%s", imp, name);
			AttrdefInfo* curr = context.registry.attrmacros.get(imp_qname) ?? null;
			while (curr != null)
			{
				if (curr.node && is_symbol_accessible_at(context, sf, loc, curr.node, curr.mod))
				{
					return curr.node;
				}
				curr = curr.next;
			}
		}
	}

	Node* found = null;
	context.modules.@each(; mod_name, mod)
	{
		if (!found && mod && (!sf || is_module_visible_at(context, sf, loc, mod_name)))
		{
			foreach (node : mod.nodes)
			{
				if (node && node.kind == ATTRDEF_DECL)
				{
					AttrdefDecl* ad = node.as(AttrdefDecl);
					if (ad.name && ad.name.text == name)
					{
						if (!sf || is_symbol_accessible_at(context, sf, loc, node, mod_name))
						{
							found = node;
							break;
						}
					}
				}
			}
		}
	};

	return found;
}

fn Node* find_callable_in_module(AnalyzerContext* context, Module* mod, String name, SourceFile* sf = null, Location loc = { -1, -1 })
{
	if (!context || !mod) return null;
	String qname = string::tformat("%s::%s", mod.name, name);
	if (context.registry)
	{
		if (try fn_info = context.registry.functions.get(qname))
		{
			if (Node* n = check_fn_list_for_function(context, fn_info, sf, loc)) return n;
		}
		if (try mac_info = context.registry.macros.get(qname))
		{
			if (Node* n = check_macro_list_for_macro(context, mac_info, sf, loc)) return n;
		}
	}
	foreach (stmt : mod.nodes)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		if (stmt.kind == FN_DECL && stmt.as(FnDecl).associated_type != null) continue;
		if (stmt.kind == MACRO_DECL && @ok(stmt.as(MacroDecl).associated_type.get())) continue;
		if (sf && !is_symbol_accessible_at(context, sf, loc, stmt, mod.name)) continue;
		String sname = cursor::spelling(stmt, tmem);
		if (sname == name || sname.strip_prefix("@") == name.strip_prefix("@"))
		{
			return stmt;
		}
	}
	return null;
}

fn Node* find_symbol_in_module(AnalyzerContext* context, Module* mod, String symbol_name, SourceFile* sf = null, Location loc = { -1, -1 })
{
	if (!context || !mod || symbol_name.len == 0) return null;

	if (Node* c = find_callable_in_module(context, mod, symbol_name, sf, loc))
	{
		return c;
	}

	String qname = string::tformat("%s::%s", mod.name, symbol_name);
	if (context.registry)
	{
		TypeInfo* curr = context.registry.types.get(qname) ?? null;
		while (curr != null)
		{
			if (curr.node && (!sf || is_symbol_accessible_at(context, sf, loc, curr.node, curr.mod)))
			{
				return curr.node;
			}
			curr = curr.next;
		}
	}

	foreach (stmt : mod.nodes)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		if (sf && !is_symbol_accessible_at(context, sf, loc, stmt, mod.name)) continue;

		String sname = cursor::spelling(stmt, tmem);
		if (sname.len > 0 && (sname == symbol_name || sname.strip_prefix("@") == symbol_name.strip_prefix("@")))
		{
			return stmt;
		}

		switch (stmt.kind)
		{
			case VAR_DECL:
				{
					VarDecl* vd = stmt.as(VarDecl);
					if (vd.name && vd.name.text == symbol_name) return stmt;
				}
			case FAULT_DECL:
				{
					FaultDecl* fd = stmt.as(FaultDecl);
					if (fd.name && fd.name.text == symbol_name) return stmt;
				}
			case FAULTDEF_DECL:
				{
					FaultdefDecl* fd = stmt.as(FaultdefDecl);
					foreach (fault_node : fd.faults)
					{
						if (!fault_node || fault_node.kind != FAULT_DECL) continue;
						if (sf && !is_symbol_accessible_at(context, sf, loc, fault_node, mod.name)) continue;
						FaultDecl* fdecl = fault_node.as(FaultDecl);
						if (fdecl.name && fdecl.name.text == symbol_name) return fault_node;
					}
				}
			case ENUM_DECL:
				{
					EnumDecl* ed = stmt.as(EnumDecl);
					foreach (variant : ed.variants)
					{
						if (!variant || variant.kind != VAR_DECL) continue;
						VarDecl* vd = variant.as(VarDecl);
						if (vd.name && vd.name.text == symbol_name) return variant;
					}
				}
			case STRUCT_DECL:
				{
					Node* mem_node = cursor::find_member_in_type(stmt, symbol_name);
					if (mem_node) return mem_node;
				}
			default:
				break;
		}
	}
	return null;
}

fn Node* find_callable_in_scope(AnalyzerContext* context, SourceFile* sf, String name, String caller_mod = "", Location loc = { -1, -1 })
{
	if (!context || !context.registry || name.len == 0) return null;

	String effective_mod = caller_mod;
	if (effective_mod.len == 0 && sf)
	{
		effective_mod = loc.line >= 0 ? get_module_name_at_location(sf, loc) : get_source_file_module_name(sf);
	}

	if (effective_mod.len > 0)
	{
		String local_qname = string::tformat("%s::%s", effective_mod, name);
		if (try fn_info = context.registry.functions.get(local_qname))
		{
			if (Node* n = check_fn_list_for_function(context, fn_info, sf, loc)) return n;
		}
		if (try mac_info = context.registry.macros.get(local_qname))
		{
			if (Node* n = check_macro_list_for_macro(context, mac_info, sf, loc)) return n;
		}
	}

	if (try fn_info = context.registry.functions.get(name))
	{
		if (Node* fn_node = check_fn_list_for_function(context, fn_info, sf, loc)) return fn_node;
	}
	if (try mac_info = context.registry.macros.get(name))
	{
		if (Node* mac_node = check_macro_list_for_macro(context, mac_info, sf, loc)) return mac_node;
	}

	String clean_name = name.strip_prefix("@");
	if (try mac_info = context.registry.macros.get(clean_name))
	{
		if (Node* mac_node = check_macro_list_for_macro(context, mac_info, sf, loc)) return mac_node;
	}

	if (sf)
	{
		List{String} imports = loc.line >= 0 ? get_imported_modules_at_location(sf, loc) : get_source_file_imported_modules(sf);
		foreach (imp : imports)
		{
			String imp_qname = string::tformat("%s::%s", imp, name);
			if (try fn_info = context.registry.functions.get(imp_qname))
			{
				if (Node* fn_node = check_fn_list_for_function(context, fn_info, sf, loc)) return fn_node;
			}
			if (try mac_info = context.registry.macros.get(imp_qname))
			{
				if (Node* mac_node = check_macro_list_for_macro(context, mac_info, sf, loc)) return mac_node;
			}
		}
	}
	return null;
}

<*
 Key of the methods of vectors whose element type is not known, as in
 generic code where it is a parameter.
*>
const String ANY_VECTOR = "[<>]";

<*
 Method `name` of `type` indexed under `key` and visible from `sf`,
 preferring one declared in `caller_mod`, or null. With `all`, every such
 method is added to it in declaration order and the first is returned.
*>
fn Node* pick_method(AnalyzerContext* context, String key, String name, String type, SourceFile* sf, Location loc, String caller_mod, List{Node*}* all = null) @local
{
	Node* found = null;
	for (MethodInfo* m = context.registry.methods_by_type.get(key) ?? null; m; m = m.next)
	{
		if (cursor::spelling(m.node, tmem).strip_prefix("@") != name) continue;
		if (!is_matching_associated_type(receiver_type_expr(m.node), type)) continue;
		if (sf && !is_symbol_accessible_at(context, sf, loc, m.node, m.mod)) continue;
		if (all)
		{
			all.push(m.node);
			continue;
		}
		if (m.mod == caller_mod) return m.node;
		if (!found) found = m.node;
	}
	if (!all || !all.len()) return found;
	quicksort(all.array_view(), &declared_before);
	return all.get(0);
}

fn int declared_before(Node* a, Node* b) @local => a.id < b.id ? -1 : a.id > b.id ? 1 : 0;

<*
 Method `method_name` of `type_name`. When the type is a vector of a generic
 element, any vector method of that name fits; `overloads`, if given,
 receives all of them.
*>
fn Node* find_method_in_type(AnalyzerContext* context, String type_name, String method_name, SourceFile* sf = null, Location loc = { -1, -1 }, List{Node*}* overloads = null)
{
	if (!context || type_name.len == 0 || method_name.len == 0) return null;

	String clean_type = type_name.trim_right("*&? \t");
	if (try idx = clean_type.index_of_char('{'))
	{
		clean_type = clean_type[:idx].trim();
	}
	clean_type = clean_type.trim_right("*&? \t");

	String name = method_name.strip_prefix("@");
	if (context.registry)
	{
		String caller_mod = sf ? (loc.line >= 0 ? get_module_name_at_location(sf, loc) : get_source_file_module_name(sf)) : "";
		if (Node* m = pick_method(context, method_key(clean_type), name, clean_type, sf, loc, caller_mod)) return m;
		if (is_vector_type(clean_type))
		{
			if (Node* m = pick_method(context, ANY_VECTOR, name, clean_type, sf, loc, caller_mod, overloads)) return m;
		}
	}

	Node* type_node = find_type_node_in_context(context, sf, clean_type);
	if (type_node)
	{
		if (type_node.kind == STRUCT_DECL)
		{
			StructDecl* sd = type_node.as(StructDecl);
			foreach (inter : sd.interfaces)
			{
				String sub_type = cursor::raw_type_identifier(inter) ?? "";
				if (sub_type.len > 0 && sub_type != clean_type)
				{
					Node* m = find_method_in_type(context, sub_type, method_name, sf, loc, overloads);
					if (m) return m;
				}
			}
			foreach (field : sd.fields)
			{
				if (!field || field.kind != VAR_DECL) continue;
				VarDecl* vd = field.as(VarDecl);
				if (vd.var_flags.is_inline && vd.type)
				{
					String sub_type = cursor::raw_type_identifier(vd.type) ?? "";
					if (sub_type.len > 0 && sub_type != clean_type)
					{
						Node* m = find_method_in_type(context, sub_type, method_name, sf, loc, overloads);
						if (m) return m;
					}
				}
			}
		}
		else if (type_node.kind == TYPEDEF_DECL)
		{
			TypedefDecl* td = type_node.as(TypedefDecl);
			if (td.is_inline && td.base_type)
			{
				String base_type = cursor::raw_type_identifier(td.base_type) ?? cursor::spelling(td.base_type, tmem);
				base_type = base_type.trim_right("*&? \t");
				if (base_type.len > 0 && base_type != clean_type)
				{
					Node* m = find_method_in_type(context, base_type, method_name, sf, loc, overloads);
					if (m) return m;
				}
			}
		}
		else if (type_node.kind == ALIAS_DECL)
		{
			AliasDecl* ad = type_node.as(AliasDecl);
			if (ad.target)
			{
				if (ad.target.kind == TERNARY_EXPR)
				{
					TernaryExpr* ter = ad.target.as(TernaryExpr);
					if (ter.then_expr)
					{
						String t_type = cursor::raw_type_identifier(ter.then_expr) ?? cursor::spelling(ter.then_expr, tmem);
						t_type = t_type.trim_right("*&? \t");
						if (t_type.len > 0 && t_type != clean_type)
						{
							Node* m = find_method_in_type(context, t_type, method_name, sf, loc, overloads);
							if (m) return m;
						}
					}
					if (ter.else_expr)
					{
						String e_type = cursor::raw_type_identifier(ter.else_expr) ?? cursor::spelling(ter.else_expr, tmem);
						e_type = e_type.trim_right("*&? \t");
						if (e_type.len > 0 && e_type != clean_type)
						{
							Node* m = find_method_in_type(context, e_type, method_name, sf, loc, overloads);
							if (m) return m;
						}
					}
				}
				else
				{
					String target_type = cursor::raw_type_identifier(ad.target) ?? cursor::spelling(ad.target, tmem);
					target_type = target_type.trim_right("*&? \t");
					if (target_type.len > 0 && target_type != clean_type)
					{
						Node* m = find_method_in_type(context, target_type, method_name, sf, loc, overloads);
						if (m) return m;
					}
				}
			}
		}
	}

	return null;
}

fn Node* find_member_in_type(AnalyzerContext* context, String type_name, String member_name, SourceFile* sf = null)
{
	if (!context || type_name.len == 0 || member_name.len == 0) return null;

	String clean_type = type_name.trim_right("*&? \t");
	if (try idx = clean_type.index_of_char('{'))
	{
		clean_type = clean_type[:idx].trim();
	}
	clean_type = clean_type.trim_right("*&? \t");

	Node* type_node = find_type_node_in_context(context, sf, clean_type);
	if (!type_node)
	{
		type_node = find_type_node_in_context(context, null, clean_type);
	}
	if (!type_node) return null;

	Node* field = cursor::find_member_in_type(type_node, member_name);
	if (field) return field;

	if (type_node.kind == STRUCT_DECL)
	{
		StructDecl* sd = type_node.as(StructDecl);
		foreach (inter : sd.interfaces)
		{
			String sub_type = cursor::raw_type_identifier(inter) ?? "";
			if (sub_type.len > 0 && sub_type != type_name)
			{
				Node* res = find_member_in_type(context, sub_type, member_name, sf);
				if (res) return res;
			}
		}
		foreach (f : sd.fields)
		{
			if (!f || f.kind != VAR_DECL) continue;
			VarDecl* vd = f.as(VarDecl);
			if (vd.var_flags.is_inline && vd.type)
			{
				String sub_type = cursor::raw_type_identifier(vd.type) ?? "";
				if (sub_type.len > 0 && sub_type != type_name)
				{
					Node* res = find_member_in_type(context, sub_type, member_name, sf);
					if (res) return res;
				}
			}
		}
	}
	else if (type_node.kind == TYPEDEF_DECL)
	{
		TypedefDecl* td = type_node.as(TypedefDecl);
		if (td.is_inline && td.base_type)
		{
			String base_type = cursor::raw_type_identifier(td.base_type) ?? cursor::spelling(td.base_type, tmem);
			base_type = base_type.trim_right("*&? \t");
			if (base_type.len > 0 && base_type != clean_type)
			{
				Node* res = find_member_in_type(context, base_type, member_name, sf);
				if (res) return res;
			}
		}
	}
	else if (type_node.kind == ALIAS_DECL)
	{
		AliasDecl* ad = type_node.as(AliasDecl);
		if (ad.target)
		{
			if (ad.target.kind == TERNARY_EXPR)
			{
				TernaryExpr* ter = ad.target.as(TernaryExpr);
				if (ter.then_expr)
				{
					String t_type = cursor::raw_type_identifier(ter.then_expr) ?? cursor::spelling(ter.then_expr, tmem);
					t_type = t_type.trim_right("*&? \t");
					if (t_type.len > 0 && t_type != clean_type)
					{
						Node* res = find_member_in_type(context, t_type, member_name, sf);
						if (res) return res;
					}
				}
				if (ter.else_expr)
				{
					String e_type = cursor::raw_type_identifier(ter.else_expr) ?? cursor::spelling(ter.else_expr, tmem);
					e_type = e_type.trim_right("*&? \t");
					if (e_type.len > 0 && e_type != clean_type)
					{
						Node* res = find_member_in_type(context, e_type, member_name, sf);
						if (res) return res;
					}
				}
			}
			else
			{
				String target_type = cursor::raw_type_identifier(ad.target) ?? cursor::spelling(ad.target, tmem);
				target_type = target_type.trim_right("*&? \t");
				if (target_type.len > 0 && target_type != clean_type)
				{
					Node* res = find_member_in_type(context, target_type, member_name, sf);
					if (res) return res;
				}
			}
		}
	}

	return null;
}

fn String type_of_symbol(AnalyzerContext* context, SourceFile* sf, Node* sym, Location loc = { -1, -1 })
{
	if (!sym) return "";
	switch (sym.kind)
	{
		case VAR_DECL:
			{
				VarDecl* vd = sym.as(VarDecl);
				if (vd.type)
				{
					String t = cursor::instance_name(vd.type);
					if (t.len > 0) return t;
				}
				if (vd.init_expr)
				{
					return type_of(context, sf, vd.init_expr, loc);
				}
			}
		case STRUCT_DECL:
		case ENUM_DECL:
		case TYPEDEF_DECL:
			return cursor::spelling(sym, tmem);
		case ALIAS_DECL:
			{
				AliasDecl* ad = sym.as(AliasDecl);
				if (ad.target)
				{
					String t = cursor::instance_name(ad.target);
					if (t.len > 0) return t;
				}
			}
		default:
			break;
	}
	return "";
}

fn Node* find_symbol_in_context(AnalyzerContext* context, SourceFile* sf, String symbol_name, Location loc = { -1, -1 })
{
	if (!context || symbol_name.len == 0) return null;

	if (symbol_name.contains("::"))
	{
		sz last_colons = symbol_name.rindex_of("::") ?? 0;
		String mod_prefix = symbol_name[:last_colons];
		String short_name = symbol_name[last_colons + 2..];
		Module* mod = resolve_module_for_prefix(context, sf, loc, mod_prefix);
		if (mod) return find_symbol_in_module(context, mod, short_name, sf, loc);
		return null;
	}

	String caller_mod = sf ? (loc.line >= 0 ? get_module_name_at_location(sf, loc) : get_source_file_module_name(sf)) : "";
	if (caller_mod.len > 0)
	{
		if (Module* m = context.modules.get(caller_mod) ?? null)
		{
			if (Node* sym = find_symbol_in_module(context, m, symbol_name, sf, loc))
			{
				return sym;
			}
		}
	}

	if (sf)
	{
		List{String} imports = loc.line >= 0 ? get_imported_modules_at_location(sf, loc) : get_source_file_imported_modules(sf);
		foreach (imp : imports)
		{
			if (Module* m = context.modules.get(imp) ?? null)
			{
				if (Node* sym = find_symbol_in_module(context, m, symbol_name, sf, loc))
				{
					return sym;
				}
			}
		}
	}

	Node* found = null;
	context.modules.@each(; mod_name, mod)
	{
		if (!found && mod && mod_name != caller_mod)
		{
			if (!sf || is_module_visible_at(context, sf, loc, mod_name))
			{
				if (Node* sym = find_symbol_in_module(context, mod, symbol_name, sf, loc))
				{
					found = sym;
				}
			}
		}
	};
	return found;
}

<*
 Canonical unified type evaluator for AST expressions.
*>
fn String type_of(AnalyzerContext* context, SourceFile* sf, Node* expr, Location loc = { -1, -1 })
{
	if (!expr || expr.kind == ERROR) return "";

	if (expr.resolved_type && expr.resolved_type.name.len > 0)
	{
		return expr.resolved_type.name;
	}

	Location effective_loc = (loc.line >= 0) ? loc : (expr ? expr.range.start : (Location){ -1, -1 });

	switch (expr.kind)
	{
		case LITERAL_EXPR:
			{
				LiteralExpr* lit = expr.as(LiteralExpr);
				switch (lit.literal_kind)
				{
					case INT_LITERAL: return "int";
					case REAL_LITERAL: return "double";
					case STRING_LITERAL: return "String";
					case BOOL_LITERAL: return "bool";
					case BYTES_LITERAL: return "char[]";
					case NULL_LITERAL: return "void*";
					default: return "";
				}
			}

		case GROUP_EXPR:
			{
				GroupExpr* ge = expr.as(GroupExpr);
				return type_of(context, sf, ge.inner, effective_loc);
			}

		case CAST_EXPR:
			{
				CastExpr* ce = expr.as(CastExpr);
				if (ce.inner)
				{
					return cursor::spelling(ce.inner, tmem);
				}
				return "";
			}

		case TYPE_EXPR:
			{
				TypeExpr* te = expr.as(TypeExpr);
				if (te.type_kind == TYPE_TYPEOF || te.type_kind == TYPE_TYPEFROM)
				{
					if (te.expr) return type_of(context, sf, te.expr, effective_loc);
				}
				return cursor::raw_type_identifier(expr) ?? "";
			}

		case UNARY_EXPR:
			return unary_type(context, sf, expr.as(UnaryExpr), effective_loc);

		case BINARY_EXPR:
			return binary_type(context, sf, expr.as(BinaryExpr), effective_loc);

		case POST_UNARY_EXPR:
			{
				PostUnaryExpr* pue = expr.as(PostUnaryExpr);
				return type_of(context, sf, pue.unary.expr, effective_loc);
			}

		case DESIGNATOR_EXPR:
			{
				DesignatorExpr* des = expr.as(DesignatorExpr);
				String collection = type_of(context, sf, des.path, effective_loc);
				switch (des.designator_kind)
				{
					case INDEX:
						return element_type(context, sf, collection, effective_loc);
					case RANGE:
						String element = element_type(context, sf, collection, effective_loc);
						return element.len ? string::tformat("%s[]", element) : "";
					case PERIOD:
						return collection;
				}
			}

		case MAYBE_DEREF_EXPR:
			{
				String pointer = type_of(context, sf, expr.as(MaybeDerefExpr).left, effective_loc);
				return pointer.ends_with("*") ? pointer[:pointer.len - 1] : pointer;
			}

		case IDENT_EXPR:
			{
				IdentExpr* ident = expr.as(IdentExpr);
				String id_name = ident.ident ? ident.ident.text : "";
				if (id_name.len == 0) return "";

				if (ident.path_expr && ident.path_expr.kind == PATH_EXPR)
				{
					String mod_name = ident.path_expr.as(PathExpr).path ? ident.path_expr.as(PathExpr).path.text.strip_suffix("::") : "";
					Module* mod = resolve_module_for_prefix(context, sf, effective_loc, mod_name);

					if (mod)
					{
						if (Node* sym = find_symbol_in_module(context, mod, id_name, sf, effective_loc))
						{
							String t = type_of_symbol(context, sf, sym, effective_loc);
							if (t.len > 0) return t;
						}
					}
				}

				String local_type;
				if (sf && find_local_decl_in_file(sf, id_name, &local_type, context, effective_loc))
				{
					if (local_type.len > 0) return local_type;
				}

				if (Node* sym = find_symbol_in_context(context, sf, id_name, effective_loc))
				{
					String t = type_of_symbol(context, sf, sym, effective_loc);
					if (t.len > 0) return t;
				}

				if (context && context.registry)
				{
					if (try ty_info = context.registry.types.get(id_name))
					{
						if (ty_info.node && (!sf || is_symbol_accessible_at(context, sf, effective_loc, ty_info.node, ty_info.mod)))
						{
							return id_name;
						}
					}
				}

				return id_name;
			}

		case ACCESS_EXPR:
			{
				AccessExpr* acc = expr.as(AccessExpr);
				String parent_type = type_of(context, sf, acc.left, effective_loc);
				if (parent_type.len == 0) return "";
				return member_type(context, sf, parent_type, cursor::spelling(acc.member, tmem), effective_loc);
			}

		case CALL_EXPR:
			{
				CallExpr* call = expr.as(CallExpr);
				if (!call.callee) return "";

				String full_name;
				if (call.callee.kind == ACCESS_EXPR)
				{
					AccessExpr* acc = call.callee.as(AccessExpr);
					String parent_type = type_of(context, sf, acc.left, effective_loc);
					String method_name = cursor::spelling(acc.member, tmem);
					if (parent_type.len > 0 && method_name.len > 0)
					{
						String t = member_type(context, sf, parent_type, method_name, effective_loc);
						if (t.len > 0) return t;
					}
					full_name = string::tformat("%s.%s", cursor::spelling(acc.left, tmem), method_name);
				}
				else if (call.callee.kind == IDENT_EXPR)
				{
					IdentExpr* ie = call.callee.as(IdentExpr);
					full_name = ie.ident ? ie.ident.text : "";
					if (ie.path_expr && ie.path_expr.kind == PATH_EXPR)
					{
						PathExpr* pe = ie.path_expr.as(PathExpr);
						if (pe.path) full_name = string::tformat("%s%s", pe.path.text, full_name);
					}
				}
				Node* ret = return_type(resolve_callee_by_name(context, sf, full_name, effective_loc));
				return ret ? cursor::instance_name(ret) : "";
			}

		default:
			return "";
	}
}

struct AccessSearchContext
{
	Range target_range;
	Node* found_access;
}

fn ChildVisitResult find_access_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	AccessSearchContext* ctx = (AccessSearchContext*)user_data;

	switch (c.kind)
	{
		case ACCESS_EXPR:
			AccessExpr* acc = c.as(AccessExpr);
			if (acc.member && acc.member.range.contains_range(ctx.target_range))
			{
				ctx.found_access = c;
				return BREAK;
			}
		default:
			break;
	}

	return RECURSE;
}

struct AncestorSearch
{
	Node* target;
	List{Node*} stack;
	bool found;
}

fn ChildVisitResult ancestor_enter(Node* c, Node* p, void* user_data) @local
{
	AncestorSearch* s = (AncestorSearch*)user_data;
	s.stack.push(c);
	if (c == s.target)
	{
		s.found = true;
		return BREAK;
	}
	if (!c || c.kind == ERROR || !c.range.contains_range(s.target.range)) return CONTINUE;
	return RECURSE;
}

fn ChildVisitResult ancestor_exit(Node* c, Node* p, void* user_data) @local
{
	AncestorSearch* s = (AncestorSearch*)user_data;
	s.stack.remove_last();
	return CONTINUE;
}

<*
 Path from a top-level statement down to `target` (inclusive), or empty.
*>
fn List{Node*} ancestors_of(SourceFile* sf, Node* target)
{
	AncestorSearch s = {.target = target };
	s.stack.tinit();
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		cursor::visit(stmt, null, {.on_enter = &ancestor_enter,.on_exit = &ancestor_exit }, &s);
		if (s.found) return s.stack;
	}
	s.stack.clear();
	return s.stack;
}

<*
 Label declared by the statement `stmt`, or null.
*>
fn Ident* label_of(Node* stmt)
{
	switch (stmt.kind)
	{
		case IF_STMT: return stmt.as(IfStmt).label;
		case SWITCH_STMT: return stmt.as(SwitchStmt).label;
		case FOR_STMT: return stmt.as(ForStmt).label;
		case WHILE_STMT: return stmt.as(WhileStmt).label;
		case DO_WHILE_STMT: return stmt.as(DoWhileStmt).label;
		case FOREACH_STMT: return stmt.as(ForeachStmt).label;
		default: return null;
	}
}

<*
 Label the break, continue or nextcase `stmt` jumps to, or null.
*>
fn Ident* jump_label(Node* stmt)
{
	switch (stmt.kind)
	{
		case CONTINUE_BREAK_STMT: return stmt.as(ContinueBreakStmt).label;
		case NEXTCASE_STMT: return stmt.as(NextcaseStmt).label;
		default: return null;
	}
}

<*
 Labeled statements enclosing `loc` in its function, innermost first.
*>
fn List{Node*} enclosing_labeled(SourceFile* sf, Location loc)
{
	List{Node*} labeled;
	labeled.tinit();
	Node* node = node_at(sf, loc);
	if (!node) return labeled;
	List{Node*} stack = ancestors_of(sf, node);
	foreach_r (n : stack)
	{
		if (n.kind == LAMBDA_EXPR) break;
		if (label_of(n)) labeled.push(n);
	}
	return labeled;
}

fn String type_name_of(Node* type_expr) @local
{
	if (!type_expr) return "";
	return cursor::raw_type_identifier(type_expr) ?? cursor::spelling(type_expr, tmem);
}

<*
 Type reached by applying a `.a.b` designator chain to `owner`.
*>
fn String designator_chain_type(AnalyzerContext* context, SourceFile* sf, String owner, Node* des) @local
{
	if (!des || des.kind != DESIGNATOR_EXPR || owner.len == 0) return "";
	DesignatorExpr* d = des.as(DesignatorExpr);
	if (d.designator_kind != PERIOD) return "";
	String base = d.path ? designator_chain_type(context, sf, owner, d.path) : owner;
	if (base.len == 0 || !d.data.field || d.data.field.kind != IDENT_EXPR) return "";
	IdentExpr* ie = d.data.field.as(IdentExpr);
	if (!ie.ident) return "";
	Node* field = find_member_in_type(context, base, ie.ident.text, sf);
	return type_of_symbol(context, sf, field);
}

<*
 What a call invokes: a function, a macro or a function pointer, its
 parameters, and the index of the first parameter that takes an argument,
 1 when the receiver of a method call is passed as `self`.
*>
struct CallTarget
{
	Node* decl;
	NodeArray params;
	sz first_param;
}

<*
 Target of `call`, resolved through its name token.
*>
fn CallTarget call_target(AnalyzerContext* context, SourceFile* sf, CallExpr* call)
{
	AccessExpr* access = call.callee && call.callee.kind == ACCESS_EXPR ? call.callee.as(AccessExpr) : null;
	Node* name = access ? access.member : call.callee;
	if (!name || name.kind != IDENT_EXPR || !name.as(IdentExpr).ident) return {};
	return target_of(context, sf, name, access);
}

<*
 Target of the call whose callee name is at `name`, in code that may not
 parse as a call yet.
*>
fn CallTarget call_target_at(AnalyzerContext* context, SourceFile* sf, Location name)
{
	Node* ident = node_at(sf, name);
	if (!ident) return {};
	List{Node*} stack = ancestors_of(sf, ident);
	sz n = stack.len();
	AccessExpr* access = n >= 2 && stack[n - 2].kind == ACCESS_EXPR && stack[n - 2].as(AccessExpr).member == ident ? stack[n - 2].as(AccessExpr) : null;
	return target_of(context, sf, ident, access);
}

<*
 Target called through the callee name `name`, the member of `access` if not null.
*>
fn CallTarget target_of(AnalyzerContext* context, SourceFile* sf, Node* name, AccessExpr* access) @local
{
	Node* decl = resolve_name(context, sf, name, access, name.range.start);
	if (!decl) return {};
	bool callable = decl.kind == FN_DECL || decl.kind == MACRO_DECL || (decl.kind == VAR_DECL && function_type(context, sf, decl.as(VarDecl).type) != null);
	if (!callable) return {};
	CallTarget target = { .decl = decl, .params = callable_params(context, sf, decl) };
	if (access && target.params.len && receiver_type_expr(decl) && access.left && access.left.kind != TYPE_EXPR) target.first_param = 1;
	return target;
}

<*
 Parameters of the callable `decl`, or none.
*>
fn NodeArray callable_params(AnalyzerContext* context, SourceFile* sf, Node* decl)
{
	switch (decl.kind)
	{
		case FN_DECL:
			return decl.as(FnDecl).params;
		case MACRO_DECL:
			return decl.as(MacroDecl).params;
		case VAR_DECL:
			TypeExpr* fn_type = function_type(context, sf, decl.as(VarDecl).type);
			return fn_type ? fn_type.func.params : {};
		default:
			return {};
	}
}

<*
 The `fn` type `type` is, directly or through aliases, or null.
*>
fn TypeExpr* function_type(AnalyzerContext* context, SourceFile* sf, Node* type) @local
{
	for (int depth = 0; depth < MAX_ALIAS_DEPTH && type && type.kind == TYPE_EXPR; depth++)
	{
		TypeExpr* te = type.as(TypeExpr);
		if (te.type_kind == TYPE_FUNCTION) return te;
		if (te.type_kind != TYPE_IDENTIFIER || !te.unresolved.name) return null;
		Node* decl = find_type_node_in_context(context, sf, te.unresolved.name.text);
		if (!decl || decl.kind != ALIAS_DECL) return null;
		type = decl.as(AliasDecl).target;
	}
	return null;
}

<*
 Type of the parameter receiving argument `arg` of `call`, or "".
 `arg` is either a positional argument or the value of a named one.
*>
fn String call_param_type(AnalyzerContext* context, SourceFile* sf, CallExpr* call, Node* arg, String arg_name) @local
{
	CallTarget target = call_target(context, sf, call);
	if (!target.decl) return "";
	NodeArray params = target.params;

	if (arg_name.len > 0)
	{
		foreach (p : params)
		{
			if (p && p.kind == VAR_DECL && p.as(VarDecl).name && p.as(VarDecl).name.text == arg_name)
			{
				return type_name_of(p.as(VarDecl).type);
			}
		}
		return "";
	}

	foreach (i, a : call.args)
	{
		if (a != arg) continue;
		sz pi = i + target.first_param;
		if (pi >= params.len || !params[pi] || params[pi].kind != VAR_DECL) return "";
		return type_name_of(params[pi].as(VarDecl).type);
	}
	return "";
}

<*
 Struct type initialized by the INITIALIZER_LIST_EXPR at `stack[idx]`, or "".
*>
fn String initializer_list_type(AnalyzerContext* context, SourceFile* sf, Node*[] stack, sz idx) @local
{
	if (idx == 0) return "";
	Node* list = stack[idx];
	Node* parent = stack[idx - 1];
	switch (parent.kind)
	{
		case VAR_DECL:
			VarDecl* vd = parent.as(VarDecl);
			if (vd.init_expr != list) return "";
			return type_name_of(vd.type);
		case COMPOUND_LITERAL_EXPR:
			return type_name_of(parent.as(CompoundLiteralExpr).type_expr);
		case CAST_EXPR:
			// `(Type){ ... }` compound literal.
			CastExpr* ce = parent.as(CastExpr);
			return ce.operand == list ? type_name_of(ce.inner) : "";
		case DESIGNATED_INITIALIZER_EXPR:
			DesignatedInitializerExpr* di = parent.as(DesignatedInitializerExpr);
			if (di.value != list || idx < 2 || stack[idx - 2].kind != INITIALIZER_LIST_EXPR) return "";
			String owner = initializer_list_type(context, sf, stack, idx - 2);
			return designator_chain_type(context, sf, owner, di.path);
		case CALL_EXPR:
			return call_param_type(context, sf, parent.as(CallExpr), list, "");
		case NAMED_ARG_EXPR:
			NamedArgExpr* na = parent.as(NamedArgExpr);
			if (na.value != list || !na.name || idx < 2 || stack[idx - 2].kind != CALL_EXPR) return "";
			return call_param_type(context, sf, stack[idx - 2].as(CallExpr), parent, na.name.text);
		case BINARY_EXPR:
			BinaryExpr* be = parent.as(BinaryExpr);
			if (be.op != OP_ASSIGN || be.right != list || !be.left) return "";
			return type_of(context, sf, be.left, list.range.start);
		case RETURN_STMT:
			for (sz i = idx; i > 0; i--)
			{
				Node* n = stack[i - 1];
				if (n.kind == FN_DECL) return type_name_of(n.as(FnDecl).ret_type);
				if (n.kind == MACRO_DECL) return type_name_of(n.as(MacroDecl).ret_type.get() ?? null);
			}
			return "";
		default:
			return "";
	}
}

<*
 If `target` is the field identifier of a `.field` designator inside an
 initializer list, set `is_designator` and return the field declaration
 (null when the initialized type cannot be determined).
*>
fn Node* resolve_designator_field(AnalyzerContext* context, SourceFile* sf, Node* target, bool* is_designator)
{
	*is_designator = false;
	if (!target || target.kind != IDENT_EXPR) return null;
	List{Node*} stack = ancestors_of(sf, target);
	sz n = stack.len();
	if (n < 2 || stack[n - 2].kind != DESIGNATOR_EXPR) return null;
	DesignatorExpr* d = stack[n - 2].as(DesignatorExpr);
	if (d.designator_kind != PERIOD || d.data.field != target) return null;
	*is_designator = true;

	sz i = n - 2;
	while (i > 0 && stack[i - 1].kind == DESIGNATOR_EXPR) i--;
	if (i < 2 || stack[i - 1].kind != DESIGNATED_INITIALIZER_EXPR || stack[i - 2].kind != INITIALIZER_LIST_EXPR) return null;

	Node*[] view = stack.array_view();
	String owner = initializer_list_type(context, sf, view, i - 2);
	String base = d.path ? designator_chain_type(context, sf, owner, d.path) : owner;
	if (base.len == 0) return null;
	return find_member_in_type(context, base, target.as(IdentExpr).ident.text, sf);
}

<*
 Innermost node under `loc`. `find_at` treats range ends as inclusive, so
 at the first character of `name` in `mod::name` it yields the `mod::`
 PATH_EXPR; the cursor is then on the name, owned by the parent.
*>
fn Node* node_at(SourceFile* sf, Location loc)
{
	if (!sf) return null;
	Node* node = cursor::find_at(sf.ast.statements.array_view(), {.start = loc,.end = loc });
	if (!node || node.kind != PATH_EXPR || node.range.contains(loc)) return node;
	List{Node*} stack = ancestors_of(sf, node);
	sz n = stack.len();
	if (n < 2) return node;
	Node* parent = stack[n - 2];
	switch (parent.kind)
	{
		case IDENT_EXPR:
			return parent.as(IdentExpr).path_expr == node ? parent : node;
		case TYPE_EXPR:
			TypeExpr* te = parent.as(TypeExpr);
			return te.type_kind == TYPE_IDENTIFIER && te.unresolved.path == node ? parent : node;
		default:
			return node;
	}
}

<*
 Generic parameter list declared by a module or top-level declaration, or null.
*>
fn GenericDecl* generics_of(Node* node)
{
	if (!node) return null;
	Node* g;
	switch (node.kind)
	{
		case MODULE_DECL: g = node.as(ModuleDecl).generics;
		case STRUCT_DECL: g = node.as(StructDecl).generics;
		case TYPEDEF_DECL: g = node.as(TypedefDecl).generics;
		case ALIAS_DECL: g = node.as(AliasDecl).generics;
		case FN_DECL: g = node.as(FnDecl).generics;
		case MACRO_DECL: g = node.as(MacroDecl).generics;
		default: return null;
	}
	return g && g.kind == GENERIC_DECL ? g.as(GenericDecl) : null;
}

<*
 Name a generic parameter is referenced by.
*>
fn String generic_param_name(Node* param)
{
	String name = cursor::spelling(param, tmem);
	if (name.len == 0) name = cursor::raw_type_identifier(param) ?? "";
	return name;
}

<*
 Type a method is declared on, or null when `decl` is no method.
*>
fn Node* receiver_type_expr(Node* decl)
{
	if (!decl) return null;
	switch (decl.kind)
	{
		case FN_DECL: return decl.as(FnDecl).associated_type;
		case MACRO_DECL: return decl.as(MacroDecl).associated_type.get() ?? null;
		default: return null;
	}
}

<*
 Return type of a function or macro, or null.
*>
fn Node* return_type(Node* callable)
{
	if (!callable) return null;
	switch (callable.kind)
	{
		case FN_DECL: return callable.as(FnDecl).ret_type;
		case MACRO_DECL: return callable.as(MacroDecl).ret_type.get() ?? null;
		default: return null;
	}
}

<*
 Type of `name` reached through a value of type `receiver`: the field's type,
 the method's return type, or `receiver.name` for a nested struct or union.
 Generic parameters are bound to the receiver's arguments. Empty when unknown.
*>
fn String member_type(AnalyzerContext* context, SourceFile* sf, String receiver, String name, Location loc = { -1, -1 })
{
	String type = receiver.trim_right("*&? \t");
	if (try property = ValueProperty::lookup_field(name, name))
	{
		String t = value_property_type(context, sf, type, property);
		if (t.len) return t;
	}

	Node* member = find_member_in_type(context, type, name, sf);
	if (member && member.kind == VAR_DECL)
	{
		VarDecl* vd = member.as(VarDecl);
		if (vd.type) return instance_type(context, sf, type, member, vd.type);
		Node* owner = find_type_node_in_context(context, sf, generic_base(type));
		return owner && owner.kind == ENUM_DECL ? type : "";
	}
	if (member && member.kind == STRUCT_DECL) return string::tformat("%s.%s", generic_base(type), name);

	Node* method = find_method_in_type(context, type, name, sf, loc);
	Node* ret = return_type(method);
	return ret ? instance_type(context, sf, type, method, ret) : "";
}

<*
 How many typedefs and aliases deep a type is followed, so that an
 invalid cycle cannot hang.
*>
const int MAX_ALIAS_DEPTH = 16;

<*
 Type of the built-in `property` of a value of type `type`, or empty when
 such values do not have it. Typedefs and aliases are followed.
*>
fn String value_property_type(AnalyzerContext* context, SourceFile* sf, String type, ValueProperty property)
{
	String t = type.trim_right("*&? \t");
	for (int depth = 0; depth < MAX_ALIAS_DEPTH && t.len; depth++)
	{
		t = builtin_definition(t);
		if (t.ends_with("]"))
		{
			switch (property)
			{
				case LEN: return "sz";
				case PTR: return t.ends_with("[]") ? string::tformat("%s*", t[:t.len - 2]) : "";
				case TYPE:
				case ORDINAL: return "";
			}
		}
		if (t == "any") return property == ValueProperty.PTR ? "void*" : property == ValueProperty.TYPE ? "typeid" : "";
		Node* decl = find_type_node_in_context(context, sf, generic_base(t));
		if (!decl) return "";
		switch (decl.kind)
		{
			case TYPEDEF_DECL:
			case ALIAS_DECL:
				t = aliased_type(context, sf, t);
			case INTERFACE_DECL:
				return property == ValueProperty.PTR ? "void*" : property == ValueProperty.TYPE ? "typeid" : "";
			case ENUM_DECL:
				EnumDecl* ed = decl.as(EnumDecl);
				if (property != ValueProperty.ORDINAL || ed.is_constdef) return "";
				return ed.backing_type ? cursor::instance_name(ed.backing_type) : "int";
			default:
				return "";
		}
	}
	return "";
}

<*
 Definition of a type the analyzer treats as built in: String is, as string
 literals are typed String without the stdlib.
*>
fn String builtin_definition(String type) @local => type == "String" ? "char[]" : type;

<*
 Type `type` stands for through its typedef or alias, with generic arguments
 bound. With `inline_only`, typedefs that are not inline are not followed.
 Empty when `type` is no such typedef or alias.
*>
fn String aliased_type(AnalyzerContext* context, SourceFile* sf, String type, bool inline_only = false) @local
{
	Node* decl = find_type_node_in_context(context, sf, generic_base(type));
	if (!decl) return "";
	switch (decl.kind)
	{
		case TYPEDEF_DECL:
			if (inline_only && !decl.as(TypedefDecl).is_inline) return "";
		case ALIAS_DECL:
			break;
		default:
			return "";
	}
	Node* inner = inner_type(decl);
	return inner ? substitute(cursor::instance_name(inner), generic_params(context, decl), generic_args(type)) : "";
}

<*
 Type of `type[i]`: the element of an array, slice, vector, pointer or
 string, or what the type's `@operator([])` returns. Empty when unknown.
*>
fn String element_type(AnalyzerContext* context, SourceFile* sf, String type, Location loc = { -1, -1 })
{
	String t = type.trim();
	for (int depth = 0; depth < MAX_ALIAS_DEPTH && t.len; depth++)
	{
		t = builtin_definition(t);
		if (t.ends_with(">]")) return t[:t.rindex_of("[<") ?? 0].trim();
		if (t.ends_with("]")) return t[:t.rindex_of_char('[') ?? 0].trim();
		if (t.ends_with("*")) return t[:t.len - 1].trim();
		if (Node* method = operator_method(context, sf, t, OV_ELEMENT_AT, loc: loc).method)
		{
			return instance_type(context, sf, t, method, return_type(method));
		}
		t = aliased_type(context, sf, t);
	}
	return "";
}

struct OperatorMatch
{
	Node* method;
	bool exact;
}

<*
 Method of the user-defined `type` overloading `kind`: with `@operator` or
 `@operator_s` when `type` is the left operand, `@operator_r` or `@operator_s`
 when it is the right one. One whose operand parameter is `other` is exact
 and preferred, as c3c does.
*>
fn OperatorMatch operator_method(AnalyzerContext* context, SourceFile* sf, String type, OverloadKind kind, bool reverse = false, String other = "", Location loc = { -1, -1 })
{
	OperatorMatch found;
	String t = type.trim_right("? \t");
	if (!context.registry || !t.len || t.ends_with("*") || t.ends_with("]")) return found;
	String base = generic_base(t);
	for (MethodInfo* op = context.registry.methods_by_type.get(method_key(base)) ?? null; op && !found.exact; op = op.next)
	{
		Node* method = op.node;
		if (!overloads(method, kind, reverse)) continue;
		Node* receiver = receiver_type_expr(method);
		if (!receiver || !is_matching_associated_type(receiver, base)) continue;
		if (sf && !is_symbol_accessible_at(context, sf, loc, method, op.mod)) continue;
		NodeArray params = method.kind == FN_DECL ? method.as(FnDecl).params : method.as(MacroDecl).params;
		bool exact = params.len > 1 && params[1] && params[1].kind == VAR_DECL && cursor::instance_name(params[1].as(VarDecl).type) == other;
		if (!found.method || exact) found = { method, exact };
	}
	return found;
}

<*
 Whether `method` overloads `kind` for the operand side given by `reverse`.
*>
fn bool overloads(Node* method, OverloadKind kind, bool reverse) @local
{
	NodeArray attributes;
	switch (method.kind)
	{
		case FN_DECL: attributes = method.as(FnDecl).attributes;
		case MACRO_DECL: attributes = method.as(MacroDecl).attributes;
		default: return false;
	}
	foreach (attr : attributes)
	{
		if (!attr || attr.kind != ATTRIBUTE_DECL) continue;
		AttributeDecl* ad = attr.as(AttributeDecl);
		switch (ad.attribute_kind)
		{
			case OPERATOR: if (reverse) continue;
			case OPERATOR_R: if (!reverse) continue;
			case OPERATOR_S: break;
			default: continue;
		}
		if (ad.exprs.len && ad.exprs[0] && ad.exprs[0].kind == OVERLOAD_EXPR && ad.exprs[0].as(OverloadExpr).overload_kind == kind) return true;
	}
	return false;
}

<*
 Type of `left op right` for an arithmetic, bitwise or shift operator:
 the return type of an overload of either operand, else pointer
 arithmetic, else numeric promotion, as c3c does. A literal combines with
 a typedef of a number as that typedef; inline typedefs and aliases are
 flattened.
*>
fn String arithmetic_type(AnalyzerContext* context, SourceFile* sf, OperatorKind op, Node* left_expr, Node* right_expr, Location loc) @local
{
	String left = type_of(context, sf, left_expr, loc);
	String right = type_of(context, sf, right_expr, loc);
	OverloadKind kind = overload_of(op);
	OperatorMatch on_left = operator_method(context, sf, left, kind, false, right, loc);
	OperatorMatch on_right = on_left.exact ? {} : operator_method(context, sf, right, kind, true, left, loc);
	if (on_left.method && (on_left.exact || !on_right.exact)) return instance_type(context, sf, left, on_left.method, return_type(on_left.method));
	if (on_right.method) return instance_type(context, sf, right, on_right.method, return_type(on_right.method));

	if (op == OP_SHL || op == OP_SHR) return promoted(context, left);
	if (left.ends_with("*"))
	{
		return op == OP_SUB && right.ends_with("*") ? "sz" : left;
	}
	if (right.ends_with("*") && op == OP_ADD) return right;
	for (int depth = 0; depth < MAX_ALIAS_DEPTH && left.len && right.len; depth++)
	{
		if (left == right) return promoted(context, left);
		if (left.ends_with(">]")) return left;
		if (right.ends_with(">]")) return right;
		Type* a = numeric(context, left);
		Type* b = numeric(context, right);
		if (a && b) return promoted(context, wider(a, b).name);
		if (b && right_expr && right_expr.kind == LITERAL_EXPR) return left;
		if (a && left_expr && left_expr.kind == LITERAL_EXPR) return right;
		String flat_left = a ? left : aliased_type(context, sf, left, true);
		String flat_right = b ? right : aliased_type(context, sf, right, true);
		if (flat_left == left && flat_right == right) return "";
		left = flat_left;
		right = flat_right;
	}
	return "";
}

fn OverloadKind overload_of(OperatorKind op) @local
{
	switch (op)
	{
		case OP_MULT: return OV_MULTIPLY;
		case OP_SUB: return OV_MINUS;
		case OP_ADD: return OV_PLUS;
		case OP_DIV: return OV_DIVIDE;
		case OP_MOD: return OV_REMINDER;
		case OP_SHR: return OV_SHR;
		case OP_SHL: return OV_SHL;
		case OP_BIT_OR: return OV_OR;
		case OP_BIT_XOR: return OV_XOR;
		case OP_BIT_AND: return OV_AND;
		default: return UNKNOWN;
	}
}

<*
 Built-in numeric type named `name`, or null.
*>
fn Type* numeric(AnalyzerContext* context, String name) @local
{
	Type* t = lookup::get_type_by_name(context.lookup, name);
	if (!t || t.status != RESOLVED) return null;
	switch (t.kind)
	{
		case TYPE_I8: case TYPE_I16: case TYPE_I32: case TYPE_I64: case TYPE_I128:
		case TYPE_U8: case TYPE_U16: case TYPE_U32: case TYPE_U64: case TYPE_U128:
		case TYPE_F16: case TYPE_BF16: case TYPE_F32: case TYPE_F64: case TYPE_F128:
		case TYPE_SZ: case TYPE_USZ: case TYPE_IPTR: case TYPE_UPTR:
			return t;
		case TYPE_VOID: case TYPE_BOOL: case TYPE_STRUCT: case TYPE_UNION: case TYPE_BITSTRUCT: case TYPE_ENUM:
			return null;
	}
}

fn uint bits(Type* t) @local => BitSizes::from_ordinal(t.data.builtin.bitsize).bits;

fn bool is_float(Type* t) @local => t.kind >= TYPE_F16 && t.kind <= TYPE_F128;

fn bool is_signed(Type* t) @local => (t.kind >= TYPE_I8 && t.kind <= TYPE_I128) || t.kind == TYPE_SZ || t.kind == TYPE_IPTR;

<*
 The wider of two numeric types: floats over integers, more bits over fewer,
 and between signed and unsigned of equal size the unsigned one.
*>
fn Type* wider(Type* a, Type* b) @local
{
	if (is_float(a) || is_float(b))
	{
		if (is_float(a) && is_float(b)) return bits(a) >= bits(b) ? a : b;
		return is_float(a) ? a : b;
	}
	if (is_signed(a) == is_signed(b)) return bits(a) >= bits(b) ? a : b;
	Type* s = is_signed(a) ? a : b;
	Type* u = is_signed(a) ? b : a;
	return bits(s) > bits(u) ? s : u;
}

<*
 `type` after arithmetic promotion: integers narrower than int become int,
 16-bit floats become float.
*>
fn String promoted(AnalyzerContext* context, String type) @local
{
	Type* t = numeric(context, type);
	if (!t) return type;
	if (is_float(t)) return bits(t) < 32 ? "float" : type;
	return bits(t) < 32 ? "int" : type;
}

<*
 Type of the binary expression `be`, by c3c's rules: comparisons and logical
 operators are bool, assignments have the left type, `??` and `?:` the left
 type without its optional.
*>
fn String binary_type(AnalyzerContext* context, SourceFile* sf, BinaryExpr* be, Location loc) @local
{
	switch (be.op)
	{
		case OP_GT:
		case OP_GE:
		case OP_LT:
		case OP_LE:
		case OP_NE:
		case OP_EQ:
		case OP_AND:
		case OP_OR:
		case OP_CT_AND:
		case OP_CT_OR:
			return "bool";
		case OP_VEC_GT:
		case OP_VEC_GE:
		case OP_VEC_LT:
		case OP_VEC_LE:
		case OP_VEC_NE:
		case OP_VEC_EQ:
			String vec = type_of(context, sf, be.left, loc);
			if (try i = vec.rindex_of("[<")) return string::tformat("bool%s", vec[i..]);
			return "bool";
		case OP_ASSIGN:
		case OP_ADD_ASSIGN:
		case OP_BIT_AND_ASSIGN:
		case OP_BIT_OR_ASSIGN:
		case OP_BIT_XOR_ASSIGN:
		case OP_DIV_ASSIGN:
		case OP_MOD_ASSIGN:
		case OP_MULT_ASSIGN:
		case OP_SHR_ASSIGN:
		case OP_SHL_ASSIGN:
		case OP_SUB_ASSIGN:
		case OP_CT_CONCAT_ASSIGN:
		case OP_CT_CONCAT:
			return type_of(context, sf, be.left, loc);
		case OP_ELSE:
		case OP_ELVIS:
			return type_of(context, sf, be.left, loc) ?: type_of(context, sf, be.right, loc);
		case OP_MULT:
		case OP_SUB:
		case OP_ADD:
		case OP_DIV:
		case OP_MOD:
		case OP_SHR:
		case OP_SHL:
		case OP_BIT_OR:
		case OP_BIT_XOR:
		case OP_BIT_AND:
			return arithmetic_type(context, sf, be.op, be.left, be.right, loc);
		case OP_ERROR:
			return "";
	}
}

<*
 Type of the unary expression `ue`: `*` dereferences, `&` takes a pointer,
 `!` is bool, `-` and `~` use an overload or numeric promotion.
*>
fn String unary_type(AnalyzerContext* context, SourceFile* sf, UnaryExpr* ue, Location loc) @local
{
	String t = type_of(context, sf, ue.expr, loc);
	if (!t.len) return "";
	switch (ue.operator)
	{
		case UNARYOP_DEREF:
			return t.ends_with("*") ? t[:t.len - 1] : "";
		case UNARYOP_ADDR:
		case UNARYOP_TADDR:
			return string::tformat("%s*", t);
		case UNARYOP_NOT:
			return "bool";
		case UNARYOP_NEG:
		case UNARYOP_BITNEG:
			OverloadKind kind = ue.operator == UNARYOP_NEG ? OV_UNARY_MINUS : OV_NEGATE;
			if (Node* method = operator_method(context, sf, t, kind, loc: loc).method) return instance_type(context, sf, t, method, return_type(method));
			return promoted(context, t);
		case UNARYOP_PLUS:
			return promoted(context, t);
		case UNARYOP_INC:
		case UNARYOP_DEC:
			return t;
		case UNARYOP_ERROR:
			return "";
	}
}

<*
 `type_expr`, declared by `member` of the type `receiver`, with the generic
 parameters of the type declaring `member` bound to the receiver's arguments.
 Typedefs, aliases and inline members are followed from `receiver` to that type.
*>
fn String instance_type(AnalyzerContext* context, SourceFile* sf, String receiver, Node* member, Node* type_expr) @local
{
	String type = cursor::instance_name(type_expr);
	String current = receiver;
	for (int depth = 0; depth < MAX_ALIAS_DEPTH && current.len; depth++)
	{
		String base = generic_base(current);
		Node* decl = find_type_node_in_context(context, sf, base) ?: find_type_node_in_context(context, null, base);
		if (!decl) break;
		GenericDecl* params = generic_params(context, decl);
		String[] args = generic_args(current);
		Node* member_receiver = receiver_type_expr(member);
		bool declared = member_receiver
			? (cursor::raw_type_identifier(member_receiver) ?? "") == base
			: decl.range.contains_range(member.range) && source_file::file_of(context, decl) == source_file::file_of(context, member);
		if (declared) return substitute(type, params, args);
		Node* inner = inner_type(decl);
		if (!inner) break;
		current = substitute(cursor::instance_name(inner), params, args);
	}
	return type;
}

<*
 Type whose members `decl` exposes as its own: an inline member's, a typedef's
 or an alias's. Null when there is none.
*>
fn Node* inner_type(Node* decl) @local
{
	switch (decl.kind)
	{
		case TYPEDEF_DECL:
			return decl.as(TypedefDecl).base_type;
		case ALIAS_DECL:
			Node* target = decl.as(AliasDecl).target;
			return target && target.kind == TYPE_EXPR ? target : null;
		case STRUCT_DECL:
			foreach (f : decl.as(StructDecl).fields)
			{
				if (f && f.kind == VAR_DECL && f.as(VarDecl).var_flags.is_inline) return f.as(VarDecl).type;
			}
			return null;
		default:
			return null;
	}
}

<*
 Generic parameters of the top-level `decl`: its own, else its module section's.
*>
fn GenericDecl* generic_params(AnalyzerContext* context, Node* decl) @local
{
	if (GenericDecl* own = generics_of(decl)) return own;
	SourceFile* sf = source_file::file_of(context, decl);
	if (!sf) return null;
	GenericDecl* section;
	foreach (stmt : sf.ast.statements)
	{
		if (stmt == decl) return section;
		if (stmt && stmt.kind == MODULE_DECL) section = generics_of(stmt);
	}
	return null;
}

<*
 `type` without its generic arguments: `Queue{Timer}` is `Queue`.
*>
fn String generic_base(String type) => type[:type.index_of_char('{') ?? type.len].trim();

<*
 Name the methods of `type` are indexed under: `std::List{int}[]*` is `List`.
*>
fn String method_key(String type) @local
{
	String t = type[:type.index_of_char('{') ?? type.len];
	t = t[:t.index_of_char('[') ?? t.len].trim_right("*&? \t");
	return t[(t.rindex_of("::") ?? -2) + 2..].trim();
}

<*
 Generic arguments of `type`: `Timer` and `false` of `Queue{Timer, false}`.
*>
fn String[] generic_args(String type) @local
{
	List{String} args;
	args.tinit();
	sz start = type.index_of_char('{') ?? type.len;
	int depth = 0;
	for (sz i = start; i < type.len; i++)
	{
		switch (type[i])
		{
			case '{':
			case '(':
			case '[':
				if (depth++ == 0) start = i + 1;
			case '}':
			case ')':
			case ']':
				if (--depth > 0) break;
				args.push(type[start:i - start].trim());
				return args.array_view();
			case ',':
				if (depth > 1) break;
				args.push(type[start:i - start].trim());
				start = i + 1;
			default:
				break;
		}
	}
	return args.array_view();
}

<*
 `type` with each identifier naming one of `params` replaced by its argument in `args`.
*>
fn String substitute(String type, GenericDecl* params, String[] args) @local
{
	if (!params || !args.len) return type;
	DString out;
	out.tinit();
	sz i = 0;
	while (i < type.len)
	{
		sz start = i;
		while (i < type.len && (type[i].is_alnum() || type[i] == '_')) i++;
		if (i == start)
		{
			out.append(type[i++]);
			continue;
		}
		String word = type[start:i - start];
		foreach (j, param : params.params)
		{
			if (j >= args.len) break;
			if (param && param.kind != ERROR && generic_param_name(param) == word)
			{
				word = args[j];
				break;
			}
		}
		out.append(word);
	}
	return out.str_view();
}

<*
 Value `name` of the enum typing the argument of an `ed` value at `loc`,
 or null when `loc` is in no such argument.
*>
fn Node* find_enum_argument_value(AnalyzerContext* context, SourceFile* sf, EnumDecl* ed, String name, Location loc) @local
{
	foreach (variant : ed.variants)
	{
		Node* values = variant.as(VarDecl).assoc_values;
		if (!values || values.kind != INITIALIZER_LIST_EXPR || !values.range.contains(loc)) continue;
		foreach (i, arg : values.as(InitializerListExpr).exprs)
		{
			if (!arg || !arg.range.contains(loc)) continue;
			if (i >= ed.assoc_params.len) return null;
			String type_name = cursor::raw_type_identifier(ed.assoc_params[i].as(VarDecl).type) ?? "";
			Node* type_node = find_type_node_in_context(context, sf, type_name, loc);
			if (!type_node || type_node.kind != ENUM_DECL) return null;
			foreach (value : type_node.as(EnumDecl).variants)
			{
				Ident* value_name = value.as(VarDecl).name;
				if (value_name && value_name.text == name) return value;
			}
			return null;
		}
	}
	return null;
}

<*
 Top-level statement containing `loc`. A declaration's range covers its doc
 contract.
*>
fn Node* enclosing_top_level(SourceFile* sf, Location loc)
{
	foreach (stmt : sf.ast.statements)
	{
		if (stmt && stmt.range.contains(loc)) return stmt;
	}
	return null;
}

<*
 Parameter `name` of the callable `decl`, or null.
*>
fn Node* find_param(AnalyzerContext* context, SourceFile* sf, Node* decl, String name) @local
{
	foreach (p : callable_params(context, sf, decl))
	{
		if (p && p.kind == VAR_DECL && p.as(VarDecl).name && p.as(VarDecl).name.text == name) return p;
	}
	return null;
}

<*
 Resolves unqualified type names in one file without walking the AST.
 Call `enter` for each top-level statement, in order: visibility only
 changes at module sections, so lookups are cached per section.
*>
struct TypeNameScope
{
	AnalyzerContext* context;
	SourceFile* sf;
	HashMap{String, Node*} decl_by_name;
	GenericDecl* section_generics;
	GenericDecl* decl_generics;
	GenericDecl* receiver_generics;
}

fn void TypeNameScope.init(&self, AnalyzerContext* context, SourceFile* sf)
{
	*self = { .context = context, .sf = sf };
	self.decl_by_name.tinit();
}

fn void TypeNameScope.enter(&self, Node* stmt)
{
	if (stmt.kind == MODULE_DECL)
	{
		self.decl_by_name.clear();
		self.section_generics = generics_of(stmt);
	}
	self.decl_generics = generics_of(stmt);
	self.receiver_generics = generics_of(self.receiver_decl(stmt));
}

<*
 Type declaration a method `stmt` is declared on, whose generic parameters
 the method can use, or null.
*>
fn Node* TypeNameScope.receiver_decl(&self, Node* stmt)
{
	Node* receiver = receiver_type_expr(stmt);
	if (!receiver || receiver.kind != TYPE_EXPR) return null;
	TypeExpr* te = receiver.as(TypeExpr);
	if (te.type_kind != TYPE_IDENTIFIER || !te.unresolved.name) return null;
	return find_type_node_in_context(self.context, self.sf, te.unresolved.name.text, te.unresolved.name.range.start);
}

fn Node* find_generic_param(GenericDecl* gd, String name) @local
{
	if (!gd) return null;
	foreach (param : gd.params)
	{
		if (param && param.kind != ERROR && generic_param_name(param) == name) return param;
	}
	return null;
}

<*
 Declaration `name` refers to at its position: a generic parameter in
 scope, else the visible type declaration, else null.
*>
fn Node* TypeNameScope.resolve(&self, Ident* name)
{
	if (Node* param = find_generic_param(self.decl_generics, name.text) ?: find_generic_param(self.receiver_generics, name.text) ?: find_generic_param(self.section_generics, name.text)) return param;
	if (try cached = self.decl_by_name.get(name.text)) return cached;
	Node* decl = find_type_node_in_context(self.context, self.sf, name.text, name.range.start);
	self.decl_by_name.set(name.text, decl);
	return decl;
}

<*
 Declaration the symbol at `loc` refers to; see `resolve_name` for `overloads`.
*>
fn Node* resolve_symbol_at(AnalyzerContext* context, SourceFile* sf, Location loc, List{Node*}* overloads = null)
{
	if (!sf) return null;
	Range target_range = {.start = loc,.end = loc };
	Node* target_node = node_at(sf, loc);
	if (!target_node || target_node.kind == ERROR) return null;

	switch (target_node.kind)
	{
		case FN_DECL:
			{
				FnDecl* fd = target_node.as(FnDecl);
				if (fd.name && fd.name.range.contains(loc)) return target_node;
			}
		case MACRO_DECL:
			{
				MacroDecl* md = target_node.as(MacroDecl);
				if (md.name && md.name.range.contains(loc)) return target_node;
			}
		case STRUCT_DECL:
			{
				StructDecl* sd = target_node.as(StructDecl);
				if (sd.name && sd.name.range.contains(loc)) return target_node;
			}
		case ENUM_DECL:
			{
				EnumDecl* ed = target_node.as(EnumDecl);
				if (ed.name && ed.name.range.contains(loc)) return target_node;
			}
		case TYPEDEF_DECL:
			{
				TypedefDecl* td = target_node.as(TypedefDecl);
				if (td.name && td.name.range.contains(loc)) return target_node;
			}
		case ALIAS_DECL:
			{
				AliasDecl* ad = target_node.as(AliasDecl);
				if (ad.name && ad.name.range.contains(loc)) return target_node;
			}
		case INTERFACE_DECL:
		case MODULE_DECL:
		case FAULT_DECL:
		case FAULTDEF_DECL:
		case ATTRDEF_DECL:
			return target_node;
		case ATTRIBUTE_DECL:
			if (target_node.as(AttributeDecl).name && context)
			{
				String caller_mod = get_module_name_at_location(sf, loc);
				Node* def = find_attrmacro_in_scope(context, sf, target_node.as(AttributeDecl).name.text, caller_mod, loc);
				if (def) return def;
			}
			return target_node;
		case VAR_DECL:
			{
				VarDecl* vd = target_node.as(VarDecl);
				if (vd.name && vd.name.range.contains(loc)) return target_node;
			}
		default:
			break;
	}

	Ident* label = label_of(target_node);
	if (label && label.range.touches(loc)) return target_node;
	label = jump_label(target_node);
	if (label && label.range.touches(loc))
	{
		foreach (n : enclosing_labeled(sf, target_node.range.start))
		{
			if (label_of(n).text == label.text) return n;
		}
		return null;
	}

	if (target_node.kind == CONTRACT_PARAM)
	{
		Ident* ident = target_node.as(ContractParam).ident;
		Node* decl = enclosing_top_level(sf, loc);
		return ident && decl ? find_param(context, sf, decl, ident.text) : null;
	}

	if (target_node.kind == NAMED_ARG_EXPR)
	{
		Ident* name = target_node.as(NamedArgExpr).name;
		List{Node*} stack = ancestors_of(sf, target_node);
		sz n = stack.len();
		if (!name || n < 2 || stack[n - 2].kind != CALL_EXPR) return null;
		Node* callee = call_target(context, sf, stack[n - 2].as(CallExpr)).decl;
		return callee ? find_param(context, sf, callee, name.text) : null;
	}

	if (target_node.kind == PATH_EXPR)
	{
		PathExpr* path_expr = target_node.as(PathExpr);
		String mod_name = path_expr.path ? path_expr.path.text.strip_suffix("::") : "";
		if (context && mod_name.len > 0)
		{
			Module* mod = resolve_module_for_prefix(context, sf, loc, mod_name);
			if (mod && mod.module_decls.len() > 0)
			{
				return (Node*)mod.module_decls.get(0);
			}
		}
		return target_node;
	}

	bool is_designator;
	Node* designated = resolve_designator_field(context, sf, target_node, &is_designator);
	if (is_designator) return designated;

	AccessSearchContext acc_ctx = {.target_range = target_range,.found_access = null };
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		cursor::visit(stmt, null, {.on_enter = &find_access_callback }, &acc_ctx);
		if (acc_ctx.found_access) break;
	}

	AccessExpr* access = acc_ctx.found_access && acc_ctx.found_access.kind == ACCESS_EXPR ? acc_ctx.found_access.as(AccessExpr) : null;
	return resolve_name(context, sf, target_node, access, loc, overloads);
}

<*
 Declaration the name `target_node` at `loc` refers to. `access` is the
 member access whose member it is, or null when it is no member.
 `overloads` receives every fitting method when more than one fits, as
 for a vector of a generic element.
*>
fn Node* resolve_name(AnalyzerContext* context, SourceFile* sf, Node* target_node, AccessExpr* access, Location loc, List{Node*}* overloads = null)
{
	String symbol_name = "";
	if (target_node.kind == TYPE_EXPR)
	{
		symbol_name = cursor::raw_type_identifier(target_node) ?? "";
	}
	if (symbol_name.len == 0 && target_node.kind == IDENT_EXPR)
	{
		IdentExpr* ie = target_node.as(IdentExpr);
		symbol_name = ie.ident ? ie.ident.text : "";
	}
	if (symbol_name.len == 0)
	{
		symbol_name = cursor::spelling(target_node, tmem);
	}
	symbol_name = symbol_name.trim_right("*&? \t");
	if (symbol_name.len == 0) return null;

	if (target_node.kind == TYPE_EXPR && constants::is_primitive(symbol_name)) return target_node;

	if (target_node.kind == IDENT_EXPR)
	{
		IdentExpr* ident_expr = target_node.as(IdentExpr);
		if (ident_expr.path_expr && ident_expr.path_expr.kind == PATH_EXPR)
		{
			PathExpr* pe = ident_expr.path_expr.as(PathExpr);
			if (pe.range.contains(loc) && !(ident_expr.ident && ident_expr.ident.range.contains(loc)))
			{
				String mod_path = pe.path ? pe.path.text.strip_suffix("::") : "";
				if (context && mod_path.len > 0)
				{
					Module* mod = resolve_module_for_prefix(context, sf, loc, mod_path);
					if (mod && mod.module_decls.len() > 0)
					{
						return (Node*)mod.module_decls.get(0);
					}
				}
				return null;
			}

			String mod_name = pe.path ? pe.path.text.strip_suffix("::") : "";
			Module* mod = resolve_module_for_prefix(context, sf, loc, mod_name);

			if (mod)
			{
				return find_symbol_in_module(context, mod, symbol_name, sf, loc);
			}
			return null;
		}
	}

	if (access)
	{
		AccessExpr* acc = access;
		String receiver_type = type_of(context, sf, acc.left, loc);

		if (receiver_type.len > 0)
		{
			Node* mnode = find_method_in_type(context, receiver_type, symbol_name, sf, loc, overloads);
			if (mnode) return mnode;

			Node* field = find_member_in_type(context, receiver_type, symbol_name, sf);
			if (field) return field;
		}

		return null;
	}

	Node* enclosing_decl = enclosing_top_level(sf, loc);
	if (enclosing_decl && enclosing_decl.kind == ENUM_DECL)
	{
		if (Node* value = find_enum_argument_value(context, sf, enclosing_decl.as(EnumDecl), symbol_name, loc)) return value;
	}

	if (!symbol_name.starts_with("@"))
	{
		Node* local_decl = null;
		if (enclosing_decl)
		{
			LocalSearchContext loc_search = {.context = context,.sf = sf,.name = symbol_name,.found_decl = null,.found_type = "" };
			cursor::visit(enclosing_decl, null, {.on_enter = &find_local_decl_callback }, &loc_search);
			local_decl = loc_search.found_decl;
		}
		else
		{
			local_decl = find_local_decl_in_file(sf, symbol_name, null, context);
		}

		if (local_decl) return local_decl;
	}

	if (target_node.kind == TYPE_EXPR)
	{
		Node* ty_node = find_type_node_in_context(context, sf, symbol_name, loc);
		if (ty_node) return ty_node;
	}

	if (context && context.registry)
	{
		TypeInfo* direct_ty = context.registry.types.get(symbol_name) ?? null;
		while (direct_ty != null)
		{
			if (direct_ty.node && is_symbol_accessible_at(context, sf, loc, direct_ty.node, direct_ty.mod))
			{
				return direct_ty.node;
			}
			direct_ty = direct_ty.next;
		}

		String caller_mod = get_module_name_at_location(sf, loc);
		if (Node* c = find_callable_in_scope(context, sf, symbol_name, caller_mod, loc)) return c;

		List{String} imports = get_imported_modules_at_location(sf, loc);
		foreach (imp : imports)
		{
			String imp_qname = string::tformat("%s::%s", imp, symbol_name);
			TypeInfo* imp_ty = context.registry.types.get(imp_qname) ?? null;
			while (imp_ty != null)
			{
				if (imp_ty.node && is_symbol_accessible_at(context, sf, loc, imp_ty.node, imp_ty.mod))
				{
					return imp_ty.node;
				}
				imp_ty = imp_ty.next;
			}
		}
	}

	if (context)
	{
		context.modules.@each(; mod_name, mod)
		{
			if (mod && is_module_visible_at(context, sf, loc, mod_name))
			{
				foreach (md : mod.module_decls)
				{
					if (GenericDecl* gd = generics_of((Node*)md))
					{
						foreach (param : gd.params)
						{
							if (!param || param.kind == ERROR) continue;
							if (generic_param_name(param) == symbol_name) return param;
						}
					}
				}

				foreach (node : mod.nodes)
				{
					if (!node || node.kind == ERROR) continue;
					if (!is_symbol_accessible_at(context, sf, loc, node, mod_name)) continue;

					GenericDecl* gd = generics_of(node);
					if (gd)
					{
						foreach (param : gd.params)
						{
							if (!param || param.kind == ERROR) continue;
							if (generic_param_name(param) == symbol_name) return param;
						}
					}
				}
			}
		};
	}

	if (Node* sym = find_symbol_in_context(context, sf, symbol_name, loc))
	{
		return sym;
	}

	return null;
}

fn Node* resolve_callee_by_name(AnalyzerContext* context, SourceFile* sf, String callee_name, Location loc = { -1, -1 })
{
	if (!context || callee_name.len == 0) return null;

	String caller_mod = sf ? (loc.line >= 0 ? get_module_name_at_location(sf, loc) : get_source_file_module_name(sf)) : "";

	if (try idx = callee_name.rindex_of("::"))
	{
		String mod_name = callee_name[:idx];
		String fn_name = callee_name[idx + 2..];

		Module* mod = resolve_module_for_prefix(context, sf, loc, mod_name);
		return find_callable_in_module(context, mod, fn_name, sf, loc);
	}

	if (try dot_idx = callee_name.rindex_of_char('.'))
	{
		String recv_name = callee_name[:dot_idx].trim();
		String method_name = callee_name[dot_idx + 1..].trim();

		while (recv_name.starts_with("(") && recv_name.ends_with(")") && recv_name.len >= 2)
		{
			recv_name = recv_name[1 : ^2].trim();
		}

		return find_method_in_type(context, recv_name, method_name, sf, loc);
	}

	return find_callable_in_scope(context, sf, callee_name, caller_mod, loc);
}

fn String file_stem_from_path(String p)
{
	sz s1 = p.rindex_of_char('/') ?? 0;
	sz s2 = p.rindex_of_char('\\') ?? 0;
	sz last_slash = s1 > s2 ? s1 : s2;
	bool has_slash = (last_slash > 0) || (p.len > 0 && (p[0] == '/' || p[0] == '\\'));
	String filename = has_slash ? p[last_slash + 1..] : p;
	if (try dot = filename.rindex_of_char('.'))
	{
		return filename[:dot];
	}
	return filename;
}