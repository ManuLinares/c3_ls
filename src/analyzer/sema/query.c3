module analyzer::sema::query;
import analyzer, std::collections::list, std::collections::fixedlist, std::collections::map, std::io, std::io::path, std::sort;

struct LocalSearchContext
{
	AnalyzerContext* context;
	SourceFile* sf;
	String name;
	Node* found_decl;
	String found_type;
	<* Only declarations in scope here count; none when the line is negative. *>
	Location loc;
	bool skip_try_bindings;
}

<*
 Whether declarations inside a node of `kind` are invisible outside it. Compile-time blocks are not scopes.
*>
fn bool opens_scope(NodeKind kind)
{
	switch (kind)
	{
		case FN_DECL:
		case MACRO_DECL:
		case LAMBDA_EXPR:
		case MACRO_BODY_EXPR:
		case COMPOUND_STMT:
		case IF_STMT:
		case SWITCH_STMT:
		case CASE_STMT:
		case DEFAULT_STMT:
		case FOR_STMT:
		case FOREACH_STMT:
		case WHILE_STMT:
		case DO_WHILE_STMT:
			return true;
		default:
			return false;
	}
}

fn ChildVisitResult find_local_decl_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	LocalSearchContext* ctx = (LocalSearchContext*)user_data;
	if (ctx.loc.line >= 0 && opens_scope(c.kind) && !c.range.contains(ctx.loc)) return CONTINUE;
	if (ctx.loc.line >= 0 && c.kind == IF_STMT && c.as(IfStmt).else_body.contains(ctx.loc))
	{
		// The `else` branch sees `catch` bindings of the c0ondition, not `try` ones, I'm tired.
		IfStmt* if_stmt = c.as(IfStmt);
		ctx.skip_try_bindings = true;
		cursor::visit(if_stmt.condition, c, {.on_enter = &find_local_decl_callback }, ctx);
		ctx.skip_try_bindings = false;
		if (!ctx.found_decl) cursor::visit(if_stmt.else_body.get()!!, c, {.on_enter = &find_local_decl_callback }, ctx);
		return ctx.found_decl ? BREAK : CONTINUE;
	}

	switch (c.kind)
	{
		case VAR_DECL:
			{
				VarDecl* vd = c.as(VarDecl);
				if (vd.name.is(ctx.name) && (vd.var_kind != VAR_LOCAL || ctx.loc.line < 0 || !ctx.loc.before(c.range.start)))
				{
					ctx.found_decl = c;
					if (try type = vd.type.get())
					{
						ctx.found_type = cursor::spelling(type, tmem);
					}
					else if (try init_expr = vd.init_expr.get())
					{
						ctx.found_type = type_of(ctx.context, ctx.sf, init_expr);
					}
					return BREAK;
				}
			}
		case TRY_EXPR:
			{
				TryExpr* te = c.as(TryExpr);
				if (ctx.skip_try_bindings || te.variable.kind != IDENT_EXPR) return RECURSE;
				IdentExpr* ie = te.variable.as(IdentExpr);
				if (ie.ident.text != ctx.name) return RECURSE;
				ctx.found_decl = c;
				if (try type = te.type.get())
				{
					ctx.found_type = cursor::spelling(type, tmem);
				}
				else if (try init = te.init.get())
				{
					String itype = type_of(ctx.context, ctx.sf, init);
					ctx.found_type = itype.trim_right("?*& \t");
				}
				return BREAK;
			}
		case CATCH_EXPR:
			{
				CatchExpr* ce = c.as(CatchExpr);
				Node*? variable = ce.variable.get();
				if (catch variable) return RECURSE;
				if (variable.kind != IDENT_EXPR) return RECURSE;
				IdentExpr* ie = variable.as(IdentExpr);
				if (ie.ident.text != ctx.name) return RECURSE;
				ctx.found_decl = c;
				ctx.found_type = ce.type.spelling() ?: "fault";
				return BREAK;
			}
		case FOREACH_STMT:
			{
				ForeachStmt* fst = c.as(ForeachStmt);
				// Without an index, `variable` is checked twice.
				foreach (binding : (Node*[]){ fst.index.get() ?? fst.variable, fst.variable })
				{
					if (binding.kind != VAR_DECL || !binding.as(VarDecl).name.is(ctx.name)) continue;
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
	if (try type = vd.type.get()) return cursor::instance_name(type);
	if (fst.index.is(binding)) return "sz";
	String element = element_type(context, sf, type_of(context, sf, fst.enumeration), fst.enumeration.range.start);
	return fst.value_by_ref && element.len ? string::tformat("%s*", element) : element;
}

fn Node*? find_local_decl_in_file(SourceFile* sf, String name, String* out_type = null, AnalyzerContext* context = null, Location loc = { -1, -1 })
{
	if (!sf || name.len == 0) return NOT_FOUND~;
	LocalSearchContext loc_search = {.context = context,.sf = sf,.name = name,.found_decl = null,.found_type = "", .loc = loc };
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
		return NOT_FOUND~;
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
	return NOT_FOUND~;
}

<*
 Letters naming vector components; a swizzle takes all of its letters from one set.
*>
const String[2] SWIZZLE_SETS = { "xyzw", "rgba" };

<*
 Whether `name` picks vector components: only letters of `xyzw`, or only of `rgba`.
*>
fn bool is_swizzle(String name)
{
	if (!name.len) return false;
	foreach (set : SWIZZLE_SETS)
	{
		bool all = true;
		foreach (c : name) all = all && @ok(set.index_of_char(c));
		if (all) return true;
	}
	return false;
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
	return md.path.get().as(PathExpr).path.text ?? "";
}

<*
 Index into `sf.ast.module_decls` of the last module section starting on or
 before the line of `loc`, or -1. A negative line means the end of the file.
*>
fn sz section_at(SourceFile* sf, Location loc)
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

<*
 Module of `sf` at `loc`, or its first module when `loc` has no line.
*>
fn String caller_module(SourceFile* sf, Location loc)
{
	if (!sf) return "";
	return loc.line >= 0 ? get_module_name_at_location(sf, loc) : get_source_file_module_name(sf);
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
 Indices in `sf.ast.statements` of the imports in the module section at
 `loc`, found by binary search in the file's sorted import index.
*>
fn sz[] section_imports(SourceFile* sf, Location loc) @local
{
	sz start_idx;
	sz end_idx;
	get_module_section_stmt_range(sf, loc, &start_idx, &end_idx);
	sz[] all = sf.ast.import_decls.array_view();
	sz from = sort::binarysearch(all, start_idx);
	sz to = sort::binarysearch(all, end_idx);
	return all[from:to - from];
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
	foreach (i : section_imports(sf, loc))
	{
		ImportDecl* imp = sf.ast.statements[i].as(ImportDecl);
		bool stmt_is_public = cursor::has_attribute((Node*)imp, PUBLIC, null);
		bool stmt_is_recursive = !cursor::has_attribute((Node*)imp, NORECURSE, null);

		foreach (p : imp.paths)
		{
			if (!p || p.kind != PATH_EXPR) continue;
			PathExpr* pe = p.as(PathExpr);
			String imp_path = pe.path.text.strip_suffix("::");
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

<*
 Modules usable as a qualifier at `loc` of `sf`.
*>
fn List{String} visible_modules(AnalyzerContext* context, SourceFile* sf, Location loc)
{
	List{String} visible;
	visible.tinit();
	if (!context) return visible;
	context.modules.@each(; name, m)
	{
		if (is_module_visible_at(context, sf, loc, name)) visible.push(name);
	};
	return visible;
}

<*
 First entry of the `head` list that `sf` can see at `loc`, best ranked first.
*>
macro Node*? @first_accessible(AnalyzerContext* context, SourceFile* sf, Location loc, head, bool $skip_methods = false)
{
	foreach (curr : ranked(context, sf, loc, head))
	{
		if (!curr.node) continue;
		$if $skip_methods:
			if (@ok(receiver_type_expr(curr.node))) continue;
		$endif
		if (!sf || is_symbol_accessible_at(context, sf, loc, curr.node, curr.mod)) return curr.node;
	}
	return NOT_FOUND~;
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

	foreach (i : section_imports(sf, loc))
	{
		ImportDecl* imp = sf.ast.statements[i].as(ImportDecl);
		foreach (p : imp.paths)
		{
			if (!p || p.kind != PATH_EXPR) continue;
			PathExpr* pe = p.as(PathExpr);
			String imp_path = pe.path.text.strip_suffix("::");
			if (imp_path.len > 0)
			{
				list.push(imp_path);
			}
		}
	}
	return list;
}

fn bool is_module_visible_at(AnalyzerContext* context, SourceFile* sf, Location loc, String target_mod)
{
	if (!sf || target_mod.len == 0) return false;

	String sf_mod = caller_module(sf, loc);
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
			String caller_mod = caller_module(sf, loc);
			if (caller_mod.len > 0 && target_mod.len > 0 && caller_mod == target_mod) return true;
			if (caller_mod.len == 0 && target_mod.len == 0 && sf.contains_node(target_node)) return true;
			if (is_imported_as_public_at(sf, loc, target_mod)) return true;
			return false;
	}
}

<*
 Adds the module `m` that a prefix names to `candidates`; whether it ends
 the search of `resolve_module_for_prefix`: no `all` list is being filled,
 and `m` declares `symbol` or no symbol is asked for.
*>
fn bool settles(AnalyzerContext* context, SourceFile* sf, Location loc, Module* m, String symbol, List{Module*}* all, List{Module*}* candidates) @local
{
	candidates.push(m);
	return !all && (!symbol.len || @ok(find_symbol_in_module(context, m, symbol, sf, loc)));
}

<*
 Module the prefix `mod_prefix` names at `loc` of `sf`: an exact name, a module
 alias, an import or a sub-module of one, tried in that order. With `symbol`,
 the first of those declaring it, as c3c resolves `env::tget_var` to
 `std::os::env` and not to `std::core::env`; the first by name if none does.
 With `all`, every module visible at `loc` that the prefix can name is added
 to it instead, as `env::` names both of those.
*>
fn Module*? resolve_module_for_prefix(AnalyzerContext* context, SourceFile* sf, Location loc, String mod_prefix, String symbol = "", List{Module*}* all = null)
{
	if (!context || mod_prefix.len == 0) return NOT_FOUND~;
	List{Module*} candidates;
	candidates.tinit();

	if (try m = context.modules.get(mod_prefix))
	{
		if (settles(context, sf, loc, m, symbol, all, &candidates)) return m;
	}

	String caller_mod = caller_module(sf, loc);

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
				if (try target = ad.target.get() && ad.alias_kind == MODULE_ALIAS && ad.name.is(mod_prefix) && target.kind == PATH_EXPR)
				{
					PathExpr* pe = target.as(PathExpr);
					String target_path = pe.path.text.strip_suffix("::");
					if (try target_mod = context.modules.get(target_path))
					{
						if (settles(context, sf, loc, target_mod, symbol, all, &candidates)) return target_mod;
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
				if (try imp_mod = context.modules.get(imp))
				{
					if (settles(context, sf, loc, imp_mod, symbol, all, &candidates)) return imp_mod;
				}
			}
		}
	}

	if (caller_mod.len > 0)
	{
		String submod_name = string::tformat("%s::%s", caller_mod, mod_prefix);
		if (try submod = context.modules.get(submod_name))
		{
			if (settles(context, sf, loc, submod, symbol, all, &candidates)) return submod;
		}
	}

	if (sf)
	{
		List{String} imports = get_imported_modules_at_location(sf, loc);
		String suffix = string::tformat("::%s", mod_prefix);
		foreach (imp : imports)
		{
			String imp_sub = string::tformat("%s::%s", imp, mod_prefix);
			if (try submod = context.modules.get(imp_sub))
			{
				if (settles(context, sf, loc, submod, symbol, all, &candidates)) return submod;
			}

			String imp_prefix = string::tformat("%s::", imp);
			context.modules.@each(; mname, m)
			{
				if (mname.starts_with(imp_prefix) && (mname == mod_prefix || mname.ends_with(suffix)))
				{
					if (settles(context, sf, loc, m, symbol, all, &candidates)) return m;
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
			if (try top_sub_mod = context.modules.get(top_sub))
			{
				if (settles(context, sf, loc, top_sub_mod, symbol, all, &candidates)) return top_sub_mod;
			}
		}
	}

	String suffix = string::tformat("::%s", mod_prefix);
	context.modules.@each(; mname, m)
	{
		if (mname == mod_prefix || mname.ends_with(suffix))
		{
			if (settles(context, sf, loc, m, symbol, all, &candidates)) return m;
		}
	};
	if (all)
	{
		foreach (mod : candidates)
		{
			if (!array::contains(all.array_view(), mod) && (!sf || is_module_visible_at(context, sf, loc, mod.name))) all.push(mod);
		}
		return all.len() ? (*all)[0] : NOT_FOUND~;
	}
	// None declares `symbol`: the first that matched by name.
	return candidates.len() ? candidates[0] : NOT_FOUND~;
}

fn Node*? find_type_node_in_context(AnalyzerContext* context, SourceFile* sf, String type_name, Location loc = { -1, -1 })
{
	if (!context || type_name.len == 0) return NOT_FOUND~;

	String clean_type = bare_type_name(type_name);

	if (constants::is_primitive(clean_type)) return NOT_FOUND~;

	if (try dot_idx = clean_type.rindex_of_char('.'))
	{
		String parent_type = clean_type[:dot_idx].trim();
		String child_name = clean_type[dot_idx + 1..].trim();
		if (try parent_node = find_type_node_in_context(context, sf, parent_type, loc) && parent_node.kind == STRUCT_DECL)
		{
			foreach (f : parent_node.as(StructDecl).fields)
			{
				if (f && f.kind == STRUCT_DECL && f.as(StructDecl).name.is(child_name))
				{
					return f;
				}
			}
		}
		return NOT_FOUND~;
	}

	if (context.registry)
	{
		if (clean_type.contains("::"))
		{
			if (try accessible = @first_accessible(context, sf, loc, context.registry.types.get(clean_type) ?? (TypeInfo*)null)) return accessible;
		}

		String caller_mod = caller_module(sf, loc);
		if (caller_mod.len > 0)
		{
			String local_qname = string::tformat("%s::%s", caller_mod, clean_type);
			if (try accessible = @first_accessible(context, sf, loc, context.registry.types.get(local_qname) ?? (TypeInfo*)null)) return accessible;
		}

		if (sf)
		{
			List{String} imports = get_imported_modules_at_location(sf, loc);
			foreach (imp : imports)
			{
				String imp_qname = string::tformat("%s::%s", imp, clean_type);
				if (try accessible = @first_accessible(context, sf, loc, context.registry.types.get(imp_qname) ?? (TypeInfo*)null)) return accessible;
			}
		}

		String suffix = string::tformat("::%s", clean_type);
		TypeInfo* matched = null;
		context.registry.types.@each(; qname, tinfo)
		{
			if (!matched && (qname == clean_type || qname.ends_with(suffix)))
			{
				foreach (curr : ranked(context, sf, loc, tinfo))
				{
					if (!sf || (is_module_visible_at(context, sf, loc, curr.mod) && is_symbol_accessible_at(context, sf, loc, curr.node, curr.mod)))
					{
						matched = curr;
						break;
					}
				}
			}
		};
		if (matched && matched.node) return matched.node;
	}

	return NOT_FOUND~;
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

<*
 Whether a method declared on the slice, array or vector type `receiver`
 applies to a value of type `target`; a receiver whose length is `*` takes any length.
 With `any_element`, the element types are not compared.
*>
fn bool receiver_accepts(String receiver, String target, bool any_element) @local
{
	if (receiver == target) return true;
	String open = receiver.ends_with("[<*>]") ? "[<" : receiver.ends_with("[*]") ? "[" : "";
	if (!open.len) return false;
	String base = receiver[:receiver.len - (open.len == 1 ? 3 : 5)];
	if (any_element) base = target[:target.rindex_of(open) ?? 0];
	if (!target.starts_with(base)) return false;
	String dims = target[base.len..];
	if (!dims.starts_with(open) || dims.starts_with("[<") != (open.len == 2) || !dims.ends_with("]")) return false;
	return !@ok(dims[1..].index_of_char('[')) && dims != "[]";
}

fn bool is_matching_associated_type(Node* assoc_type_node, String clean_type, String type_name = "", bool any_element = false)
{
	if (!assoc_type_node) return false;

	String target_clean = bare_type_name(clean_type);

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
			assoc_raw = te.unresolved.name.text();
			if (try path = te.unresolved.path.get() && path.kind == PATH_EXPR) assoc_path = path.as(PathExpr).path.text.strip_suffix("::");
		}
	}

	TypeExprKind assoc_kind = assoc_type_node.kind == TYPE_EXPR ? assoc_type_node.as(TypeExpr).type_kind : TYPE_IDENTIFIER;
	// A slice, array or vector receiver is matched as a whole type, never by its element type alone.
	if (assoc_kind == TYPE_SLICE || assoc_kind == TYPE_ARRAY || assoc_kind == TYPE_VECTOR) return receiver_accepts(cursor::instance_name(assoc_type_node), target_clean, any_element);
	if (assoc_raw.len == 0 && assoc_kind != TYPE_VECTOR)
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
		if (is_matching_associated_type(assoc_type_node, type_name, any_element: any_element)) return true;
	}

	if (is_vector_type(target_clean))
	{
		String assoc_spell = cursor::spelling(assoc_type_node, tmem).trim_right("*&? \t");
		if (is_vector_type(assoc_spell) || is_vector_type(assoc_raw)) return true;
	}

	return false;
}

fn Node*? check_fn_list_for_function(AnalyzerContext* context, FunctionInfo* head, SourceFile* sf = null, Location loc = { -1, -1 })
	=> @first_accessible(context, sf, loc, head, $skip_methods: true);

fn Node*? check_macro_list_for_macro(AnalyzerContext* context, MacroInfo* head, SourceFile* sf = null, Location loc = { -1, -1 })
	=> @first_accessible(context, sf, loc, head, $skip_methods: true);

fn Node*? find_attrmacro_in_scope(AnalyzerContext* context, SourceFile* sf, String name, String caller_mod = "", Location loc = { -1, -1 })
{
	if (!context || !context.registry || name.len == 0) return NOT_FOUND~;

	if (caller_mod.len > 0)
	{
		String local_qname = string::tformat("%s::%s", caller_mod, name);
		if (try accessible = @first_accessible(context, sf, loc, context.registry.attrmacros.get(local_qname) ?? (AttrdefInfo*)null)) return accessible;
	}

	if (sf)
	{
		List{String} imports = get_imported_modules_at_location(sf, loc);
		foreach (imp : imports)
		{
			String imp_qname = string::tformat("%s::%s", imp, name);
			if (try accessible = @first_accessible(context, sf, loc, context.registry.attrmacros.get(imp_qname) ?? (AttrdefInfo*)null)) return accessible;
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
					if (ad.name.is(name))
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

	return found ?: NOT_FOUND~;
}

fn Node*? find_callable_in_module(AnalyzerContext* context, Module* mod, String name, SourceFile* sf = null, Location loc = { -1, -1 })
{
	if (!context || !mod) return NOT_FOUND~;
	String qname = string::tformat("%s::%s", mod.name, name);
	if (context.registry)
	{
		if (try fn_info = context.registry.functions.get(qname))
		{
			if (try n = check_fn_list_for_function(context, fn_info, sf, loc)) return n;
		}
		if (try mac_info = context.registry.macros.get(qname))
		{
			if (try n = check_macro_list_for_macro(context, mac_info, sf, loc)) return n;
		}
	}
	foreach (stmt : mod.nodes)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		if (stmt.kind == FN_DECL && @ok(stmt.as(FnDecl).associated_type.get())) continue;
		if (stmt.kind == MACRO_DECL && @ok(stmt.as(MacroDecl).associated_type.get())) continue;
		if (sf && !is_symbol_accessible_at(context, sf, loc, stmt, mod.name)) continue;
		String sname = cursor::spelling(stmt, tmem);
		if (sname == name || sname.strip_prefix("@") == name.strip_prefix("@"))
		{
			return stmt;
		}
	}
	return NOT_FOUND~;
}

fn Node*? find_symbol_in_module(AnalyzerContext* context, Module* mod, String symbol_name, SourceFile* sf = null, Location loc = { -1, -1 })
{
	if (!context || !mod || symbol_name.len == 0) return NOT_FOUND~;

	if (try c = find_callable_in_module(context, mod, symbol_name, sf, loc))
	{
		return c;
	}

	String qname = string::tformat("%s::%s", mod.name, symbol_name);
	if (context.registry)
	{
		if (try accessible = @first_accessible(context, sf, loc, context.registry.types.get(qname) ?? (TypeInfo*)null)) return accessible;
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
					if (vd.name.is(symbol_name)) return stmt;
				}
			case FAULT_DECL:
				{
					FaultDecl* fd = stmt.as(FaultDecl);
					if (fd.name.is(symbol_name)) return stmt;
				}
			case FAULTDEF_DECL:
				{
					FaultdefDecl* fd = stmt.as(FaultdefDecl);
					foreach (fault_node : fd.faults)
					{
						if (!fault_node || fault_node.kind != FAULT_DECL) continue;
						if (sf && !is_symbol_accessible_at(context, sf, loc, fault_node, mod.name)) continue;
						FaultDecl* fdecl = fault_node.as(FaultDecl);
						if (fdecl.name.is(symbol_name)) return fault_node;
					}
				}
			case ENUM_DECL:
				{
					EnumDecl* ed = stmt.as(EnumDecl);
					foreach (variant : ed.variants)
					{
						if (!variant || variant.kind != VAR_DECL) continue;
						VarDecl* vd = variant.as(VarDecl);
						if (vd.name.is(symbol_name)) return variant;
					}
				}
			case STRUCT_DECL:
				{
					if (try mem_node = cursor::find_member_in_type(stmt, symbol_name)) return mem_node;
				}
			default:
				break;
		}
	}
	return NOT_FOUND~;
}

fn Node*? find_callable_in_scope(AnalyzerContext* context, SourceFile* sf, String name, String caller_mod = "", Location loc = { -1, -1 })
{
	if (!context || !context.registry || name.len == 0) return NOT_FOUND~;

	String effective_mod = caller_mod;
	if (effective_mod.len == 0 && sf)
	{
		effective_mod = caller_module(sf, loc);
	}

	if (effective_mod.len > 0)
	{
		String local_qname = string::tformat("%s::%s", effective_mod, name);
		if (try fn_info = context.registry.functions.get(local_qname))
		{
			if (try n = check_fn_list_for_function(context, fn_info, sf, loc)) return n;
		}
		if (try mac_info = context.registry.macros.get(local_qname))
		{
			if (try n = check_macro_list_for_macro(context, mac_info, sf, loc)) return n;
		}
	}

	if (try fn_info = context.registry.functions.get(name))
	{
		if (try fn_node = check_fn_list_for_function(context, fn_info, sf, loc)) return fn_node;
	}
	if (try mac_info = context.registry.macros.get(name))
	{
		if (try mac_node = check_macro_list_for_macro(context, mac_info, sf, loc)) return mac_node;
	}

	String clean_name = name.strip_prefix("@");
	if (try mac_info = context.registry.macros.get(clean_name))
	{
		if (try mac_node = check_macro_list_for_macro(context, mac_info, sf, loc)) return mac_node;
	}

	if (sf)
	{
		List{String} imports = get_imported_modules_at_location(sf, loc);
		foreach (imp : imports)
		{
			String imp_qname = string::tformat("%s::%s", imp, name);
			if (try fn_info = context.registry.functions.get(imp_qname))
			{
				if (try fn_node = check_fn_list_for_function(context, fn_info, sf, loc)) return fn_node;
			}
			if (try mac_info = context.registry.macros.get(imp_qname))
			{
				if (try mac_node = check_macro_list_for_macro(context, mac_info, sf, loc)) return mac_node;
			}
		}
	}
	return NOT_FOUND~;
}

<*
 Whether the element type of the vector `type` is no type known at `loc`,
 as in generic code where it is a parameter.
*>
fn bool has_unknown_element(AnalyzerContext* context, SourceFile* sf, String type, Location loc)
{
	if (!is_vector_type(type)) return false;
	String element = type[:type.index_of("[<") ?? 0];
	return !constants::is_primitive(element) && !@ok(find_type_node_in_context(context, sf, element, loc));
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
fn Node* pick_method(AnalyzerContext* context, String key, String name, String type, SourceFile* sf, Location loc, String caller_mod, List{Node*}* all = null, bool any_element = false) @local
{
	Node* found = null;
	foreach (m : ranked(context, sf, loc, context.registry.methods_by_type.get(key) ?? (MethodInfo*)null))
	{
		if (cursor::spelling(m.node, tmem).strip_prefix("@") != name) continue;
		if (!(is_matching_associated_type(receiver_type_expr(m.node), type, any_element: any_element) ?? false)) continue;
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
 `type` followed by the types whose methods a value of `type` also has: the
 base of an inline typedef, what an alias names, the interfaces a struct
 implements or an interface extends, and a struct's inline members.
*>
fn List{String} method_sources(AnalyzerContext* context, SourceFile* sf, Location loc, String type)
{
	List{String} sources;
	sources.tinit();
	sources.push(type);
	for (sz i = 0; i < sources.len() && i < MAX_ALIAS_DEPTH; i++)
	{
		String clean = generic_base(sources[i]).trim_right("*&? \t");
		Node*? decl = find_type_node_in_context(context, sf, clean, loc);
		if (catch decl) continue;
		switch (decl.kind)
		{
			case TYPEDEF_DECL:
				TypedefDecl* td = decl.as(TypedefDecl);
				// A typedef of a pointer does not reach the pointee's methods.
				if (try base = td.base_type.get() && td.is_inline && !(base.kind == TYPE_EXPR && base.as(TypeExpr).type_kind == TYPE_POINTER)) add_method_source(&sources, cursor::instance_name(base));
			case ALIAS_DECL:
				foreach (aliased : alias_targets(decl.as(AliasDecl))) add_method_source(&sources, aliased);
			case STRUCT_DECL:
				StructDecl* sd = decl.as(StructDecl);
				foreach (inter : sd.interfaces) add_method_source(&sources, cursor::raw_type_identifier(inter) ?? "");
				foreach (field : sd.fields)
				{
					if (field && field.kind == VAR_DECL) add_method_source(&sources, cursor::inline_type(field.as(VarDecl)) ?? "");
				}
			case INTERFACE_DECL:
				foreach (parent : decl.as(InterfaceDecl).interfaces) add_method_source(&sources, cursor::raw_type_identifier(parent) ?? "");
			default:
				break;
		}
	}
	return sources;
}

fn void add_method_source(List{String}* sources, String type) @local
{
	String source = type.trim_right("*&? \t");
	if (source.len && !array::contains(sources.array_view(), source)) sources.push(source);
}

<*
 Method `method_name` of `type_name`. When the type is a vector of a generic
 element, any vector method of that name fits; `overloads`, if given,
 receives all of them.
*>
fn Node*? find_method_in_type(AnalyzerContext* context, String type_name, String method_name, SourceFile* sf = null, Location loc = { -1, -1 }, List{Node*}* overloads = null)
{
	if (!context || type_name.len == 0 || method_name.len == 0) return NOT_FOUND~;
	String name = method_name.strip_prefix("@");
	String caller_mod = caller_module(sf, loc);
	foreach (source : method_sources(context, sf, loc, type_name))
	{
		String clean_type = generic_base(source).trim_right("*&? \t");
		if (context.registry)
		{
			if (Node* m = pick_method(context, method_key(clean_type), name, clean_type, sf, loc, caller_mod)) return m;
			if (is_vector_type(clean_type))
			{
				if (Node* m = pick_method(context, ANY_VECTOR, name, clean_type, sf, loc, caller_mod, overloads, has_unknown_element(context, sf, clean_type, loc))) return m;
			}
		}
		if (try decl = find_type_node_in_context(context, sf, clean_type, loc) && decl.kind == INTERFACE_DECL)
		{
			foreach (m : decl.as(InterfaceDecl).methods)
			{
				if (m && m.kind == FN_DECL && m.as(FnDecl).name.is(name)) return m;
			}
		}
	}
	return NOT_FOUND~;
}

<*
 Types the alias `ad` stands for: its target, or both branches of a ternary target.
*>
fn FixedList{String, 2} alias_targets(AliasDecl* ad)
{
	FixedList{String, 2} out;
	Node*? target = ad.target.get();
	if (catch target) return out;
	if (target.kind == TERNARY_EXPR)
	{
		out.push(cursor::instance_name(target.as(TernaryExpr).then_expr));
		out.push(cursor::instance_name(target.as(TernaryExpr).else_expr));
	}
	else
	{
		out.push(cursor::instance_name(target));
	}
	return out;
}

fn Node*? find_member_in_type(AnalyzerContext* context, String type_name, String member_name, SourceFile* sf = null, Location loc = { -1, -1 })
{
	if (!context || type_name.len == 0 || member_name.len == 0) return NOT_FOUND~;

	String clean_type = bare_type_name(type_name);

	Node* type_node = find_type_node_in_context(context, sf, clean_type, loc) ?? find_type_node_in_context(context, null, clean_type)!;

	List{Node*} variants;
	variants.tinit();
	usable_variants(context, sf, loc, type_node, &variants);
	foreach (variant : variants)
	{
		if (try member = member_of_type_node(context, variant, type_name, clean_type, member_name, sf, loc)) return member;
	}
	return NOT_FOUND~;
}

<*
 Member `member_name` of the type declaration `type_node`, named `type_name`
 and `clean_type` without generic arguments, including those it embeds.
*>
fn Node*? member_of_type_node(AnalyzerContext* context, Node* type_node, String type_name, String clean_type, String member_name, SourceFile* sf, Location loc) @local
{
	if (try field = cursor::find_member_in_type(type_node, member_name)) return field;

	if (type_node.kind == STRUCT_DECL)
	{
		StructDecl* sd = type_node.as(StructDecl);
		foreach (inter : sd.interfaces)
		{
			String sub_type = cursor::raw_type_identifier(inter) ?? "";
			if (sub_type.len > 0 && sub_type != type_name)
			{
				if (try res = find_member_in_type(context, sub_type, member_name, sf, loc)) return res;
			}
		}
		foreach (f : sd.fields)
		{
			if (!f || f.kind != VAR_DECL) continue;
			VarDecl* vd = f.as(VarDecl);
			if (try sub_type = cursor::inline_type(vd) && sub_type != type_name)
			{
				if (try res = find_member_in_type(context, sub_type, member_name, sf, loc)) return res;
			}
		}
	}
	else if (type_node.kind == TYPEDEF_DECL)
	{
		// A typedef keeps the fields of what it wraps; only `inline` keeps the methods.
		TypedefDecl* td = type_node.as(TypedefDecl);
		if (try base = td.base_type.get())
		{
			String base_type = cursor::instance_name(base);
			base_type = base_type.trim_right("*&? \t");
			if (base_type.len > 0 && base_type != clean_type)
			{
				if (try res = find_member_in_type(context, base_type, member_name, sf, loc)) return res;
			}
		}
	}
	else if (type_node.kind == ALIAS_DECL)
	{
		AliasDecl* ad = type_node.as(AliasDecl);
		foreach (aliased : alias_targets(ad))
		{
			String target_type = aliased.trim_right("*&? \t");
			if (target_type.len > 0 && target_type != clean_type)
			{
				if (try res = find_member_in_type(context, target_type, member_name, sf, loc)) return res;
			}
		}
	}

	return NOT_FOUND~;
}

fn String type_of_symbol(AnalyzerContext* context, SourceFile* sf, Node* sym, Location loc = { -1, -1 })
{
	if (!sym) return "";
	switch (sym.kind)
	{
		case VAR_DECL:
			{
				VarDecl* vd = sym.as(VarDecl);
				if (try type = vd.type.get())
				{
					String t = cursor::instance_name(type);
					if (t.len > 0) return t;
				}
				if (try init_expr = vd.init_expr.get())
				{
					return type_of(context, sf, init_expr, loc);
				}
			}
		case STRUCT_DECL:
		case ENUM_DECL:
		case TYPEDEF_DECL:
			return cursor::spelling(sym, tmem);
		case ALIAS_DECL:
			{
				AliasDecl* ad = sym.as(AliasDecl);
				Node*? alias_target = ad.target.get();
				if (catch alias_target) break;
				if (ad.alias_kind != IDENT_ALIAS)
				{
					String t = cursor::instance_name(alias_target);
					if (t.len > 0) return t;
					break;
				}
				// `alias tmem = current_temp;` has the type of what it names, resolved where declared.
				SourceFile* alias_sf = source_file::file_of(context, sym) ?? sf;
				Ident* ident = alias_target.kind == IDENT_EXPR ? alias_target.as(IdentExpr).ident : null;
				if (try target = resolve_name(context, alias_sf, alias_target, null, ident ? ident.range.start : alias_target.range.start) && target != sym)
				{
					return type_of_symbol(context, alias_sf, target);
				}
			}
		default:
			break;
	}
	return "";
}

fn Node*? find_symbol_in_context(AnalyzerContext* context, SourceFile* sf, String symbol_name, Location loc = { -1, -1 })
{
	if (!context || symbol_name.len == 0) return NOT_FOUND~;

	if (symbol_name.contains("::"))
	{
		sz last_colons = symbol_name.rindex_of("::") ?? 0;
		String mod_prefix = symbol_name[:last_colons];
		String short_name = symbol_name[last_colons + 2..];
		return find_symbol_in_module(context, resolve_module_for_prefix(context, sf, loc, mod_prefix, short_name), short_name, sf, loc);
	}

	String caller_mod = caller_module(sf, loc);
	if (caller_mod.len > 0)
	{
		if (try m = context.modules.get(caller_mod))
		{
			if (try sym = find_symbol_in_module(context, m, symbol_name, sf, loc))
			{
				return sym;
			}
		}
	}

	if (sf)
	{
		List{String} imports = get_imported_modules_at_location(sf, loc);
		foreach (imp : imports)
		{
			if (try m = context.modules.get(imp))
			{
				if (try sym = find_symbol_in_module(context, m, symbol_name, sf, loc))
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
				if (try sym = find_symbol_in_module(context, mod, symbol_name, sf, loc))
				{
					found = sym;
				}
			}
		}
	};
	return found ?: NOT_FOUND~;
}

<*
 Canonical unified type evaluator for AST expressions.
*>
fn String type_of(AnalyzerContext* context, SourceFile* sf, Node* expr, Location loc = { -1, -1 })
{
	if (!expr || expr.kind == ERROR) return "";

	if (try resolved = expr.resolved_type.get() && resolved.name.len > 0) return resolved.name;

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
				return cursor::spelling(ce.inner, tmem);
			}

		case TYPE_EXPR:
			{
				TypeExpr* te = expr.as(TypeExpr);
				if (te.type_kind == TYPE_TYPEOF || te.type_kind == TYPE_TYPEFROM) return type_of(context, sf, te.expr, effective_loc);
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
				String collection = type_of(context, sf, des.path.get(), effective_loc) ?? "";
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
				String id_name = ident.ident.text;
				if (id_name.len == 0) return "";

				if (try path = ident.path_expr.get())
				{
					String mod_name = path.as(PathExpr).path.text.strip_suffix("::");
					if (try mod = resolve_module_for_prefix(context, sf, effective_loc, mod_name, id_name))
					{
						if (try sym = find_symbol_in_module(context, mod, id_name, sf, effective_loc))
						{
							String t = type_of_symbol(context, sf, sym, effective_loc);
							if (t.len > 0) return t;
						}
					}
				}

				String local_type;
				if (sf && @ok(find_local_decl_in_file(sf, id_name, &local_type, context, effective_loc)))
				{
					if (local_type.len > 0) return local_type;
				}

				if (try sym = find_symbol_in_context(context, sf, id_name, effective_loc))
				{
					String t = type_of_symbol(context, sf, sym, effective_loc);
					if (t.len > 0) return t;
				}

				return id_name;
			}

		case ACCESS_EXPR:
			{
				AccessExpr* acc = expr.as(AccessExpr);
				// `T::kind` is a TypeKind whatever `T` is, even a compile-time `$Type`.
				if (acc.access_kind == STATIC && @ok(acc.member.get()))
				{
					if (try p = TypeProperty::lookup_field(name, acc.member.spelling()))
					{
						if (!p.type_desc.starts_with("any") && !p.type_desc.starts_with("fn")) return p.type_desc;
					}
				}
				String parent_type = type_of(context, sf, acc.left, effective_loc);
				if (parent_type.len == 0) return "";
				return member_type(context, sf, parent_type, acc.member.spelling(), effective_loc);
			}

		case CALL_EXPR:
			{
				CallExpr* call = expr.as(CallExpr);

				String full_name;
				Node* name_node = call.callee.kind == GENERIC_IDENT_EXPR ? call.callee.as(GenericIdentExpr).left : call.callee;
				if (call.callee.kind == ACCESS_EXPR)
				{
					AccessExpr* acc = call.callee.as(AccessExpr);
					String parent_type = type_of(context, sf, acc.left, effective_loc);
					String method_name = acc.member.spelling();
					if (parent_type.len > 0 && method_name.len > 0)
					{
						String t = member_type(context, sf, parent_type, method_name, effective_loc);
						if (t.len > 0) return t;
					}
					full_name = string::tformat("%s.%s", cursor::spelling(acc.left, tmem), method_name);
				}
				else if (name_node && name_node.kind == IDENT_EXPR)
				{
					IdentExpr* ie = name_node.as(IdentExpr);
					full_name = ie.ident.text;
					if (try path = ie.path_expr.get()) full_name = string::tformat("%s%s", path.as(PathExpr).path.text, full_name);
				}
				Node*? callee_decl = resolve_callee_by_name(context, sf, full_name, effective_loc);
				if (catch callee_decl) return "";
				Node*? ret = return_type(callee_decl);
				if (catch ret) return "";
				GenericIdentExpr* generic = call.callee.kind == GENERIC_IDENT_EXPR ? call.callee.as(GenericIdentExpr) : null;
				return bound_type(context, sf, cursor::instance_name(ret), call_binding(context, sf, callee_decl, null, generic));
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
			// A `$eval(...)` member is not a name; what it contains is resolved on its own.
			if (try member = acc.member.get() && member.kind == IDENT_EXPR && member.range.contains_range(ctx.target_range))
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
 @require target != null
*>
fn List{Node*} ancestors_of(SourceFile* sf, Node* target)
{
	AncestorSearch s = {.target = target };
	s.stack.tinit();
	// The declaration holding `target` is found by binary search; scanning every statement is the fallback.
	Node*? top = enclosing_top_level(sf, target.range.start);
	if (try top && top.kind != ERROR)
	{
		cursor::visit(top, null, {.on_enter = &ancestor_enter,.on_exit = &ancestor_exit }, &s);
		if (s.found) return s.stack;
		s.stack.clear();
	}
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
fn Ident*? label_of(Node* stmt)
{
	switch (stmt.kind)
	{
		case IF_STMT: return stmt.as(IfStmt).label.get();
		case SWITCH_STMT: return stmt.as(SwitchStmt).label.get();
		case FOR_STMT: return stmt.as(ForStmt).label.get();
		case WHILE_STMT: return stmt.as(WhileStmt).label.get();
		case DO_WHILE_STMT: return stmt.as(DoWhileStmt).label.get();
		case FOREACH_STMT: return stmt.as(ForeachStmt).label.get();
		default: return NOT_FOUND~;
	}
}

<*
 Label the break, continue or nextcase `stmt` jumps to, or null.
*>
fn Ident*? jump_label(Node* stmt)
{
	switch (stmt.kind)
	{
		case CONTINUE_BREAK_STMT: return stmt.as(ContinueBreakStmt).label.get();
		case NEXTCASE_STMT: return stmt.as(NextcaseStmt).label.get();
		default: return NOT_FOUND~;
	}
}

<*
 Labeled statements enclosing `loc` in its function, innermost first.
*>
fn List{Node*} enclosing_labeled(SourceFile* sf, Location loc)
{
	List{Node*} labeled;
	labeled.tinit();
	Node*? node = node_at(sf, loc);
	if (catch node) return labeled;
	List{Node*} stack = ancestors_of(sf, node);
	foreach_r (n : stack)
	{
		if (n.kind == LAMBDA_EXPR) break;
		if (@ok(label_of(n))) labeled.push(n);
	}
	return labeled;
}

<*
 Type reached by applying a `.a[i].b` designator chain to `owner`.
*>
fn String designator_chain_type(AnalyzerContext* context, SourceFile* sf, String owner, Node* des) @local
{
	if (!des || des.kind != DESIGNATOR_EXPR || owner.len == 0) return "";
	DesignatorExpr* d = des.as(DesignatorExpr);
	String base = designator_chain_type(context, sf, owner, d.path.get()) ?? owner;
	if (d.designator_kind != PERIOD) return element_type(context, sf, base);
	if (try field = d.data.field.get() && base.len > 0 && field.kind == IDENT_EXPR) return member_type(context, sf, base, field.as(IdentExpr).ident.text);
	return "";
}

<*
 Generic parameters and the arguments bound to them.
*>
struct GenericBinding
{
	NullableGenerics params;
	String[] args;
}

<*
 What a call invokes: a function, a macro or a function pointer, its
 parameters, and the index of the first parameter that takes an argument,
 1 when the receiver of a method call is passed as `self`. `binding` holds
 the generic arguments of the call: the receiver's, as for `list.push` on a
 `List{Entry}`, or the explicit ones of `first{Entry}(...)`.
*>
struct CallTarget
{
	Node* decl;
	NodeArray params;
	sz first_param;
	GenericBinding binding;
}

<*
 Target of `call`, resolved through its name token.
*>
fn CallTarget call_target(AnalyzerContext* context, SourceFile* sf, CallExpr* call)
{
	AccessExpr* access = call.callee.kind == ACCESS_EXPR ? call.callee.as(AccessExpr) : null;
	Node*? name = access ? access.member.get() : call.callee;
	if (catch name) return {};
	GenericIdentExpr* generic = name.kind == GENERIC_IDENT_EXPR ? name.as(GenericIdentExpr) : null;
	if (generic) name = generic.left;
	if (name.kind != IDENT_EXPR) return {};
	return target_of(context, sf, name, access, generic);
}

<*
 Target of the call whose callee name is at `name`, in code that may not
 parse as a call yet.
*>
fn CallTarget call_target_at(AnalyzerContext* context, SourceFile* sf, Location name)
{
	Node*? ident = node_at(sf, name);
	if (catch ident) return {};
	List{Node*} stack = ancestors_of(sf, ident);
	sz n = stack.len();
	AccessExpr* access = n >= 2 && stack[n - 2].kind == ACCESS_EXPR && stack[n - 2].as(AccessExpr).member.is(ident) ? stack[n - 2].as(AccessExpr) : null;
	GenericIdentExpr* generic = n >= 2 && stack[n - 2].kind == GENERIC_IDENT_EXPR && stack[n - 2].as(GenericIdentExpr).left == ident ? stack[n - 2].as(GenericIdentExpr) : null;
	return target_of(context, sf, ident, access, generic);
}

<*
 Target called through the callee name `name`, the member of `access` if not null.
*>
fn CallTarget target_of(AnalyzerContext* context, SourceFile* sf, Node* name, AccessExpr* access, GenericIdentExpr* generic) @local
{
	// At the identifier: in `mod::name` the start is on `mod::`, naming the module.
	Ident* ident = name.kind == IDENT_EXPR ? name.as(IdentExpr).ident : null;
	Node*? decl = resolve_name(context, sf, name, access, ident ? ident.range.start : name.range.start);
	if (catch decl) return {};
	bool callable = decl.kind == FN_DECL || decl.kind == MACRO_DECL || (decl.kind == VAR_DECL && @ok(function_type(context, sf, decl.as(VarDecl).type.get())));
	if (!callable) return {};
	CallTarget target = { .decl = decl, .params = callable_params(context, sf, decl), .binding = call_binding(context, sf, decl, access, generic) };
	if (access && target.params.len && @ok(receiver_type_expr(decl)) && access.left.kind != TYPE_EXPR) target.first_param = 1;
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
			return function_type(context, sf, decl.as(VarDecl).type.get()).func.params ?? {};
		default:
			return {};
	}
}

<*
 The `fn` type `type` is, directly or through aliases, or null.
*>
fn TypeExpr*? function_type(AnalyzerContext* context, SourceFile* sf, Node* type) @local
{
	for (int depth = 0; depth < MAX_ALIAS_DEPTH && type && type.kind == TYPE_EXPR; depth++)
	{
		TypeExpr* te = type.as(TypeExpr);
		if (te.type_kind == TYPE_FUNCTION) return te;
		if (te.type_kind != TYPE_IDENTIFIER) return NOT_FOUND~;
		Node* decl = find_type_node_in_context(context, sf, te.unresolved.name.get().text)!;
		if (decl.kind != ALIAS_DECL) return NOT_FOUND~;
		type = decl.as(AliasDecl).target.get()!;
	}
	return NOT_FOUND~;
}

<*
 Generic arguments the callable `decl` is called with: those of the
 receiver of `access`, or the explicit ones of `generic`.
*>
fn GenericBinding call_binding(AnalyzerContext* context, SourceFile* sf, Node* decl, AccessExpr* access, GenericIdentExpr* generic) @local
{
	if (access && access.left.kind != TYPE_EXPR)
	{
		String receiver = type_of(context, sf, access.left, access.range.start);
		return receiver.len ? member_binding(context, sf, receiver, decl) : {};
	}
	if (!generic) return {};
	List{String} args;
	args.tinit();
	foreach (arg : generic.exprs) args.push(arg ? cursor::instance_name(arg) : "");
	return { ast::@nullable(generic_params(context, decl)), args.array_view() };
}

<*
 Where a macro body first gives a type to its untyped parameter `name`:
 the variable declared as `T x = #init`, or the left side of `x = #init`.
*>
struct ExpansionSearch
{
	String name;
	Node* declared_type;
	Node* assigned_to;
}

fn ChildVisitResult find_expansion_callback(Node* c, Node* p, void* user_data) @local
{
	ExpansionSearch* search = user_data;
	switch (c.kind)
	{
		case VAR_DECL:
			VarDecl* vd = c.as(VarDecl);
			if (try type = vd.type.get() && try init_expr = vd.init_expr.get() && names_param(init_expr, search.name)) search.declared_type = type;
		case BINARY_EXPR:
			BinaryExpr* be = c.as(BinaryExpr);
			if (be.op == OP_ASSIGN && names_param(be.right, search.name)) search.assigned_to = be.left;
		default:
			break;
	}
	return search.declared_type || search.assigned_to ? BREAK : RECURSE;
}

fn bool names_param(Node* expr, String name) @local
{
	return expr && expr.kind == IDENT_EXPR && expr.as(IdentExpr).ident.text == name;
}

<*
 Declared type of the parameter `param` of `target` called as `call`. An
 untyped macro parameter, as `#init` of `mem::new($Type, #init)`, has the
 type c3c gives the argument where the body expands it, as `$Type` in
 `*val = #init` for a `$Type* val`, with the macro's `$` type parameters
 bound to the call's arguments.
*>
fn String param_type(AnalyzerContext* context, SourceFile* sf, CallTarget target, CallExpr* call, VarDecl* param) @local
{
	if (try type = param.type.get()) return bound_type(context, sf, cursor::instance_name(type), target.binding);
	Ident*? ident = param.name.get();
	if (catch ident) return "";
	if (!target.decl || target.decl.kind != MACRO_DECL) return "";
	Node*? body = target.decl.as(MacroDecl).body.get();
	if (catch body) return "";
	ExpansionSearch search = { .name = ident.text };
	cursor::visit(body, null, { .on_enter = &find_expansion_callback }, &search);
	SourceFile* macro_sf = source_file::file_of(context, target.decl) ?? sf;
	String type;
	if (search.declared_type) type = cursor::instance_name(search.declared_type);
	if (search.assigned_to) type = type_of(context, macro_sf, search.assigned_to, search.assigned_to.range.start);
	if (!type.len) return "";
	foreach (pi, p : target.params)
	{
		if (!p || p.kind != VAR_DECL || pi < target.first_param) continue;
		Ident*? param_name = p.as(VarDecl).name.get();
		if (catch param_name) continue;
		String name = param_name.text;
		sz ai = pi - target.first_param;
		if (!name.starts_with("$") || ai >= call.args.len || !call.args[ai] || call.args[ai].kind != TYPE_EXPR) continue;
		if (!type.starts_with(name) || (type.len > name.len && lexer::is_ident(type[name.len]))) continue;
		return string::tformat("%s%s", cursor::instance_name(call.args[ai]), type[name.len..]);
	}
	return type.starts_with("$") ? "" : type;
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
			if (p && p.kind == VAR_DECL && p.as(VarDecl).name.is(arg_name))
			{
				return param_type(context, sf, target, call, p.as(VarDecl));
			}
		}
		return "";
	}

	foreach (i, a : call.args)
	{
		if (a != arg) continue;
		sz pi = i + target.first_param;
		if (pi >= params.len || !params[pi] || params[pi].kind != VAR_DECL) return "";
		return param_type(context, sf, target, call, params[pi].as(VarDecl));
	}
	return "";
}

<*
 Type of the value of the DESIGNATED_INITIALIZER_EXPR at `stack[idx]`, or "".
*>
fn String designated_value_type(AnalyzerContext* context, SourceFile* sf, Node*[] stack, sz idx) @local
{
	if (idx < 1 || stack[idx - 1].kind != INITIALIZER_LIST_EXPR) return "";
	String owner = initializer_list_type(context, sf, stack, idx - 1);
	return designator_chain_type(context, sf, owner, stack[idx].as(DesignatedInitializerExpr).path);
}

<*
 Type initialized by the INITIALIZER_LIST_EXPR at `stack[idx]`, or "".
*>
fn String initializer_list_type(AnalyzerContext* context, SourceFile* sf, Node*[] stack, sz idx) @local
{
	Node* list = stack[idx];
	while (idx > 0 && stack[idx - 1].kind == GROUP_EXPR) list = stack[--idx];
	if (idx == 0) return "";
	Node* parent = stack[idx - 1];
	switch (parent.kind)
	{
		case VAR_DECL:
			VarDecl* vd = parent.as(VarDecl);
			if (!vd.init_expr.is(list)) return "";
			return cursor::instance_name(vd.type.get()) ?? "";
		case COMPOUND_LITERAL_EXPR:
			Node* type = parent.as(CompoundLiteralExpr).type_expr;
			return type ? cursor::instance_name(type) : "";
		case CAST_EXPR:
			// `(Type){ ... }` compound literal.
			CastExpr* ce = parent.as(CastExpr);
			return ce.operand == list ? cursor::instance_name(ce.inner) : "";
		case INITIALIZER_LIST_EXPR:
			sz position = array::index_of(parent.as(InitializerListExpr).exprs, list) ?? -1;
			// An element of an enum variant's associated values has its parameter's type.
			if (idx >= 3 && stack[idx - 2].kind == VAR_DECL && stack[idx - 2].as(VarDecl).assoc_values.is(parent) && stack[idx - 3].kind == ENUM_DECL)
			{
				NodeArray params = stack[idx - 3].as(EnumDecl).assoc_params;
				if (position < 0 || position >= params.len || !params[position] || params[position].kind != VAR_DECL) return "";
				return cursor::instance_name(params[position].as(VarDecl).type.get()) ?? "";
			}
			String owner = initializer_list_type(context, sf, stack, idx - 1);
			if (owner.len == 0) return "";
			Node*? type_node = find_type_node_in_context(context, sf, owner);
			if (catch type_node) return element_type(context, sf, owner);
			if (type_node.kind != STRUCT_DECL) return element_type(context, sf, owner);
			NodeArray fields = type_node.as(StructDecl).fields;
			if (position < 0 || position >= fields.len) return "";
			Node* field = fields[position];
			if (!field) return "";
			return member_type(context, sf, owner, cursor::decl_name(field).text) ?? "";
		case DESIGNATED_INITIALIZER_EXPR:
			if (parent.as(DesignatedInitializerExpr).value != list) return "";
			return designated_value_type(context, sf, stack, idx - 1);
		case CALL_EXPR:
			return call_param_type(context, sf, parent.as(CallExpr), list, "");
		case NAMED_ARG_EXPR:
			NamedArgExpr* na = parent.as(NamedArgExpr);
			if (na.value != list || idx < 2 || stack[idx - 2].kind != CALL_EXPR) return "";
			return call_param_type(context, sf, stack[idx - 2].as(CallExpr), parent, na.name.text);
		case BINARY_EXPR:
			BinaryExpr* be = parent.as(BinaryExpr);
			if (be.op != OP_ASSIGN || be.right != list) return "";
			return type_of(context, sf, be.left, list.range.start);
		case RETURN_STMT:
			for (sz i = idx; i > 0; i--)
			{
				Node* n = stack[i - 1];
				if (n.kind == FN_DECL || n.kind == MACRO_DECL) return cursor::instance_name(return_type(n)) ?? "";
			}
			return "";
		default:
			return "";
	}
}

<*
 Type expected at `loc` inside an initializer list, or "": the list's type
 at an element, the type whose member the designator `.a.|` names, or the
 type of the value after `.a =`.
*>
fn String initializer_slot_type(AnalyzerContext* context, SourceFile* sf, Location loc)
{
	Node*? node = node_at(sf, loc);
	if (catch node) return "";
	List{Node*} stack = ancestors_of(sf, node);
	if (stack.len() == 0) return "";
	Node*[] view = stack.array_view();
	sz top = stack.len() - 1;
	if (top > 0 && stack[top - 1].kind == DESIGNATOR_EXPR && stack[top - 1].as(DesignatorExpr).data.field == node) node = stack[--top];
	Node* parent = top > 0 ? stack[top - 1] : null;

	switch
	{
		case node.kind == INITIALIZER_LIST_EXPR:
			return initializer_list_type(context, sf, view, top);
		case node.kind == DESIGNATED_INITIALIZER_EXPR:
			return designated_value_type(context, sf, view, top);
		case node.kind == DESIGNATOR_EXPR:
			sz i = top;
			while (i > 0 && stack[i - 1].kind == DESIGNATOR_EXPR) i--;
			if (i > 0 && stack[i - 1].kind == DESIGNATED_INITIALIZER_EXPR) i--;
			if (i < 1 || stack[i - 1].kind != INITIALIZER_LIST_EXPR) return "";
			String owner = initializer_list_type(context, sf, view, i - 1);
			return designator_chain_type(context, sf, owner, node.as(DesignatorExpr).path.get()) ?? owner;
		case !parent:
			return "";
		case parent.kind == DESIGNATED_INITIALIZER_EXPR && parent.as(DesignatedInitializerExpr).value == node:
			return designated_value_type(context, sf, view, top - 1);
		case parent.kind == INITIALIZER_LIST_EXPR:
			return initializer_list_type(context, sf, view, top - 1);
		default:
			return "";
	}
}

<*
 Innermost `switch` or `$switch` statement around `loc`, or null.
*>
fn Node*? enclosing_switch(SourceFile* sf, Location loc)
{
	Node* node = node_at(sf, loc)!;
	foreach_r (n : ancestors_of(sf, node))
	{
		if (n.kind == SWITCH_STMT || n.kind == CT_SWITCH_STMT) return n;
	}
	return NOT_FOUND~;
}

<*
 If `target` is the field identifier of a `.field` designator inside an
 initializer list, set `is_designator` and return the field declaration
 (null when the initialized type cannot be determined).
*>
fn Node*? resolve_designator_field(AnalyzerContext* context, SourceFile* sf, Node* target, bool* is_designator)
{
	*is_designator = false;
	if (!target || target.kind != IDENT_EXPR) return NOT_FOUND~;
	List{Node*} stack = ancestors_of(sf, target);
	sz n = stack.len();
	if (n < 2 || stack[n - 2].kind != DESIGNATOR_EXPR) return NOT_FOUND~;
	DesignatorExpr* d = stack[n - 2].as(DesignatorExpr);
	if (d.designator_kind != PERIOD || d.data.field != target) return NOT_FOUND~;
	*is_designator = true;

	sz i = n - 2;
	while (i > 0 && stack[i - 1].kind == DESIGNATOR_EXPR) i--;
	if (i > 0 && stack[i - 1].kind == DESIGNATED_INITIALIZER_EXPR) i--;
	if (i < 1 || stack[i - 1].kind != INITIALIZER_LIST_EXPR) return NOT_FOUND~;

	Node*[] view = stack.array_view();
	String owner = initializer_list_type(context, sf, view, i - 1);
	String base = designator_chain_type(context, sf, owner, d.path.get()) ?? owner;
	if (base.len == 0) return NOT_FOUND~;
	return find_member_in_type(context, base, target.as(IdentExpr).ident.text, sf);
}

<*
 Innermost node under `loc`. `find_at` treats range ends as inclusive, so
 at the first character of `name` in `mod::name` it yields the `mod::`
 PATH_EXPR; the cursor is then on the name, owned by the parent.
*>
fn Node*? node_at(SourceFile* sf, Location loc)
{
	if (!sf) return NOT_FOUND~;
	Range at = {.start = loc,.end = loc };
	// The declaration holding `loc` is found by binary search; scanning every statement is the fallback.
	Node*? in_top = NOT_FOUND~;
	if (try top = enclosing_top_level(sf, loc)) in_top = cursor::find_at((Node*[1]){ top }[..], at);
	Node* node = in_top ?? cursor::find_at(sf.ast.statements.array_view(), at)!;
	if (node.kind != PATH_EXPR || node.range.contains(loc)) return node;
	List{Node*} stack = ancestors_of(sf, node);
	sz n = stack.len();
	if (n < 2) return node;
	Node* parent = stack[n - 2];
	switch (parent.kind)
	{
		case IDENT_EXPR:
			return parent.as(IdentExpr).path_expr.is(node) ? parent : node;
		case TYPE_EXPR:
			TypeExpr* te = parent.as(TypeExpr);
			return te.type_kind == TYPE_IDENTIFIER && te.unresolved.path.is(node) ? parent : node;
		default:
			return node;
	}
}

<*
 Generic parameter list declared by a module or top-level declaration, or null.
*>
fn GenericDecl*? generics_of(Node* node)
{
	if (!node) return NOT_FOUND~;
	Node*? g;
	switch (node.kind)
	{
		case MODULE_DECL: g = node.as(ModuleDecl).generics.get();
		case STRUCT_DECL: g = node.as(StructDecl).generics.get();
		case TYPEDEF_DECL: g = node.as(TypedefDecl).generics.get();
		case ALIAS_DECL: g = node.as(AliasDecl).generics.get();
		case FN_DECL: g = node.as(FnDecl).generics.get();
		case MACRO_DECL: g = node.as(MacroDecl).generics.get();
		default: return NOT_FOUND~;
	}
	if (try decl = g && decl.kind == GENERIC_DECL) return decl.as(GenericDecl);
	return NOT_FOUND~;
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
 Generic parameters in scope at `loc`: those of the enclosing declaration,
 of the type a method is declared on, and of the module section.
*>
fn List{Node*} generic_params_at(AnalyzerContext* context, SourceFile* sf, Location loc)
{
	List{Node*} params;
	params.tinit();
	if (!sf) return params;
	// The declaration, the type a method is declared on, and the module section.
	FixedList{Node*, 3} owners;
	if (try decl = enclosing_top_level(sf, loc))
	{
		owners.push(decl);
		if (try receiver = receiver_type_expr(decl))
		{
			if (try type = find_type_node_in_context(context, sf, cursor::raw_type_identifier(receiver) ?? "")) owners.push(type);
		}
	}
	sz section = section_at(sf, loc);
	if (section >= 0) owners.push(sf.ast.statements[sf.ast.module_decls[section]]);
	foreach (owner : owners)
	{
		GenericDecl*? gd = generics_of(owner);
		if (catch gd) continue;
		foreach (p : gd.params)
		{
			if (p && p.kind != ERROR) params.push(p);
		}
	}
	return params;
}

<*
 Type a method is declared on, or null when `decl` is no method.
*>
fn Node*? receiver_type_expr(Node* decl)
{
	if (!decl) return NOT_FOUND~;
	switch (decl.kind)
	{
		case FN_DECL: return decl.as(FnDecl).associated_type.get();
		case MACRO_DECL: return decl.as(MacroDecl).associated_type.get();
		default: return NOT_FOUND~;
	}
}

<*
 Return type of a function or macro, or null.
*>
fn Node*? return_type(Node* callable)
{
	if (!callable) return NOT_FOUND~;
	switch (callable.kind)
	{
		case FN_DECL: return callable.as(FnDecl).ret_type;
		case MACRO_DECL: return callable.as(MacroDecl).ret_type.get();
		default: return NOT_FOUND~;
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
	if (is_swizzle(name))
	{
		// One component is the element; several make a vector of them.
		String vector = type;
		for (int depth = 0; depth < MAX_ALIAS_DEPTH && vector.len && !is_vector_type(vector); depth++) vector = aliased_type(context, sf, vector);
		if (is_vector_type(vector))
		{
			String element = element_type(context, sf, vector, loc);
			return name.len == 1 ? element : string::tformat("%s[<%d>]", element, name.len);
		}
	}

	Node*? member = find_member_in_type(context, type, name, sf, loc);
	if (try member && member.kind == VAR_DECL)
	{
		VarDecl* vd = member.as(VarDecl);
		if (try member_type = vd.type.get()) return instance_type(context, sf, type, member, member_type);
		if (try owner = find_type_node_in_context(context, sf, generic_base(type)) && owner.kind == ENUM_DECL) return type;
		return "";
	}
	if (try member && member.kind == STRUCT_DECL) return string::tformat("%s.%s", generic_base(type), name);

	Node*? method = find_method_in_type(context, type, name, sf, loc);
	if (catch method) return "";
	return instance_type(context, sf, type, method, return_type(method)) ?? "";
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
				default: return "";
			}
		}
		if (t == "any") return property == ValueProperty.PTR ? "void*" : property == ValueProperty.TYPE ? "typeid" : "";
		if (t == "fault") return property == ValueProperty.TYPE ? "typeid" : property == ValueProperty.DESCRIPTION ? "String" : "";
		// The properties of a `typeid` available at runtime.
		if (t == "typeid")
		{
			switch (property)
			{
				case KIND: return "TypeKind";
				case SIZE:
				case LEN: return "sz";
				case PARENT:
				case INNER: return "typeid";
				case NAMES: return "String[]";
				default: return "";
			}
		}
		Node*? decl = find_type_node_in_context(context, sf, generic_base(t));
		if (catch decl) return "";
		switch (decl.kind)
		{
			case TYPEDEF_DECL:
			case ALIAS_DECL:
				t = aliased_type(context, sf, t);
			case INTERFACE_DECL:
				return property == ValueProperty.PTR ? "void*" : property == ValueProperty.TYPE ? "typeid" : "";
			case ENUM_DECL:
				EnumDecl* ed = decl.as(EnumDecl);
				if (ed.is_constdef) return "";
				if (property == ValueProperty.DESCRIPTION) return "String";
				if (property != ValueProperty.ORDINAL) return "";
				return cursor::instance_name(ed.backing_type.get()) ?? "int";
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
fn String aliased_type(AnalyzerContext* context, SourceFile* sf, String type, bool inline_only = false)
{
	Node*? decl = find_type_node_in_context(context, sf, generic_base(type));
	if (catch decl) return "";
	switch (decl.kind)
	{
		case TYPEDEF_DECL:
			if (inline_only && !decl.as(TypedefDecl).is_inline) return "";
		case ALIAS_DECL:
			break;
		default:
			return "";
	}
	return substitute(cursor::instance_name(inner_type(decl)), ast::@nullable(generic_params(context, decl)), generic_args(type)) ?? "";
}

<*
 Type of `type[i]`: the element of an array, slice, vector, pointer or
 string, or what the type's `@operator([])` returns. Empty when unknown.
*>
fn String element_type(AnalyzerContext* context, SourceFile* sf, String type, Location loc = { -1, -1 })
{
	String t = type.trim();
	bool past_typedef;
	for (int depth = 0; depth < MAX_ALIAS_DEPTH && t.len; depth++)
	{
		t = builtin_definition(t);
		if (t.ends_with(">]")) return t[:t.rindex_of("[<") ?? 0].trim();
		if (t.ends_with("]")) return t[:t.rindex_of_char('[') ?? 0].trim();
		if (t.ends_with("*")) return t[:t.len - 1].trim();
		if (!past_typedef)
		{
			if (Node* method = operator_method(context, sf, t, OV_ELEMENT_AT, loc: loc).method)
			{
				return instance_type(context, sf, t, method, return_type(method)) ?? "";
			}
		}
		// Only built-in indexing reaches through a typedef; overloads do not.
		if (try decl = find_type_node_in_context(context, sf, generic_base(t), loc) && decl.kind == TYPEDEF_DECL) past_typedef = true;
		t = aliased_type(context, sf, t);
	}
	return "";
}

<*
 How well an operator overload's operand parameter takes the other operand,
 worst first, as c3c ranks them: untyped, by conversion, or of its exact type.
*>
enum MatchLevel : char
{
	NO_MATCH,
	WILDCARD,
	CONVERSION,
	EXACT,
}

struct OperatorMatch
{
	Node* method;
	MatchLevel level;
}

<*
 Method of the user-defined `type` overloading `kind`: with `@operator` or
 `@operator_s` when `type` is the left operand, `@operator_r` or `@operator_s`
 when it is the right one. The best match for the operand type `other` is
 taken, as c3c does; without `other` the first. Aliases of `type` are followed.
*>
fn OperatorMatch operator_method(AnalyzerContext* context, SourceFile* sf, String type, OverloadKind kind, bool reverse = false, String other = "", Location loc = { -1, -1 })
{
	String t = type.trim_right("? \t");
	for (int depth = 0; depth < MAX_ALIAS_DEPTH && t.len; depth++)
	{
		OperatorMatch found = declared_operator_method(context, sf, t, kind, reverse, other, loc);
		if (found.method) return found;
		// A typedef, even an inline one, is a type of its own without the overloads of what it wraps.
		Node*? decl = find_type_node_in_context(context, sf, generic_base(t), loc);
		if (catch decl) return {};
		if (decl.kind != ALIAS_DECL) return {};
		t = aliased_type(context, sf, t);
	}
	return {};
}

<*
 Overload of `kind` declared on `type` itself; see `operator_method`.
*>
fn OperatorMatch declared_operator_method(AnalyzerContext* context, SourceFile* sf, String t, OverloadKind kind, bool reverse, String other, Location loc) @local
{
	OperatorMatch found;
	if (!context.registry || !t.len || t.ends_with("*") || t.ends_with("]")) return found;
	String base = generic_base(t);
	foreach (op : ranked(context, sf, loc, context.registry.methods_by_type.get(method_key(base)) ?? (MethodInfo*)null))
	{
		if (found.level == EXACT) break;
		Node* method = op.node;
		if (!overloads(method, kind, reverse)) continue;
		if (!(is_matching_associated_type(receiver_type_expr(method), base) ?? false)) continue;
		if (sf && !is_symbol_accessible_at(context, sf, loc, method, op.mod)) continue;
		NodeArray params = method.kind == FN_DECL ? method.as(FnDecl).params : method.as(MacroDecl).params;
		Node*? operand = params.len > 1 && params[1] && params[1].kind == VAR_DECL ? params[1].as(VarDecl).type.get() : NOT_FOUND~;
		MatchLevel level = EXACT;
		if (other.len)
		{
			level = CONVERSION;
			if (params.len > 1 && !@ok(operand)) level = WILDCARD;
			if ((cursor::instance_name(operand) ?? "") == other) level = EXACT;
		}
		if (level > found.level) found = { method, level };
	}
	return found;
}

<*
 Whether `method` overloads `kind` for the operand side given by `reverse`.
*>
fn bool overloads(Node* method, OverloadKind kind, bool reverse) @local
{
	foreach (attr : cursor::attributes(method))
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
	OverloadCall call = binary_overload(context, sf, op.overload, left, right, loc);
	if (call.method) return instance_type(context, sf, call.receiver, call.method, return_type(call.method)) ?? "";

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
		Type*? a = numeric(context, left);
		Type*? b = numeric(context, right);
		if (try w = wider(a, b)) return promoted(context, w.name);
		if (@ok(b) && right_expr && right_expr.kind == LITERAL_EXPR) return left;
		if (@ok(a) && left_expr && left_expr.kind == LITERAL_EXPR) return right;
		String flat_left = @ok(a) ? left : aliased_type(context, sf, left, true);
		String flat_right = @ok(b) ? right : aliased_type(context, sf, right, true);
		if (flat_left == left && flat_right == right) return "";
		left = flat_left;
		right = flat_right;
	}
	return "";
}

<*
 An operator overload method and the type of the operand it is called on.
*>
struct OverloadCall
{
	Node* method;
	String receiver;
}

<*
 Overload of `kind` called by `left op right`: the operand's whose overload
 matches the other operand better, as c3c resolves them. c3c rejects a tie;
 the left one is taken then.
*>
fn OverloadCall binary_overload(AnalyzerContext* context, SourceFile* sf, OverloadKind kind, String left, String right, Location loc) @local
{
	OperatorMatch on_left = operator_method(context, sf, left, kind, false, right, loc);
	OperatorMatch on_right = on_left.level == EXACT ? {} : operator_method(context, sf, right, kind, true, left, loc);
	if (on_left.method && on_left.level >= on_right.level) return { on_left.method, left };
	return on_right.method ? { on_right.method, right } : {};
}

<*
 Overload methods called by the operator token at `loc`: a binary or unary
 operator, the brackets of an index, or `lengthof`. A derived operator gives
 the overload it is derived from: `!=` uses `==`; `>`, `<=` and `>=` use `<`;
 a combined assignment such as `+=` uses `+` when it has no overload of its own.
*>
fn void operator_overloads_at(AnalyzerContext* context, SourceFile* sf, Location loc, List{OverloadCall}* out)
{
	if (!sf || !sf.lexer) return;
	sz token = sf.lexer.token_at(loc);
	if (token < 0) return;
	Location at = sf.lexer.tokens[token].range.start;
	Node*? at_node = node_at(sf, loc);
	if (catch at_node) return;
	List{Node*} stack = ancestors_of(sf, at_node);
	foreach_r (i, node : stack)
	{
		if (!node || at.before(node.range.start)) continue;
		switch (node.kind)
		{
			case BINARY_EXPR:
				BinaryExpr* be = node.as(BinaryExpr);
				if (at.before(be.left.range.end) || !at.before(be.right.range.start)) continue;
				String left = type_of(context, sf, be.left, loc);
				String right = type_of(context, sf, be.right, loc);
				if (be.op.assign_overload != UNKNOWN)
				{
					if (Node* method = operator_method(context, sf, left, be.op.assign_overload, false, right, loc).method)
					{
						out.push({ method, left });
						return;
					}
				}
				if (be.op.overload == UNKNOWN) return;
				OverloadCall call = binary_overload(context, sf, be.op.overload, left, right, loc);
				if (call.method) out.push(call);
				return;
			case UNARY_EXPR:
				UnaryExpr* ue = node.as(UnaryExpr);
				if (!at.before(ue.expr.range.start)) continue;
				OverloadKind kind;
				switch (ue.operator)
				{
					case UNARYOP_NEG: kind = OV_UNARY_MINUS;
					case UNARYOP_BITNEG: kind = OV_NEGATE;
					default: return;
				}
				String operand = type_of(context, sf, ue.expr, loc);
				if (Node* method = operator_method(context, sf, operand, kind, loc: loc).method) out.push({ method, operand });
				return;
			case DESIGNATOR_EXPR:
				DesignatorExpr* d = node.as(DesignatorExpr);
				Node*? path = d.path.get();
				if (catch path) continue;
				if (d.designator_kind != INDEX || at.before(path.range.end)) continue;
				Node* index = d.data.range;
				if (index && !at.before(index.range.start) && at.before(index.range.end)) continue;
				Node* parent = i > 0 ? stack[i - 1] : null;
				OverloadKind kind = OV_ELEMENT_AT;
				if (parent && parent.kind == BINARY_EXPR && parent.as(BinaryExpr).op == OP_ASSIGN && parent.as(BinaryExpr).left == node) kind = OV_ELEMENT_SET;
				if (parent && parent.kind == UNARY_EXPR && parent.as(UnaryExpr).operator == UNARYOP_ADDR) kind = OV_ELEMENT_REF;
				String container = type_of(context, sf, path, loc);
				if (Node* method = operator_method(context, sf, container, kind, loc: loc).method) out.push({ method, container });
				return;
			case LENGTHOF_EXPR:
				Node* inner = node.as(LengthofExpr).inner_expr;
				if (!inner || !at.before(inner.range.start)) continue;
				String measured = type_of(context, sf, inner, loc);
				if (Node* method = operator_method(context, sf, measured, OV_LEN, loc: loc).method) out.push({ method, measured });
				return;
			default:
				continue;
		}
	}
}

<*
 Built-in numeric type named `name`, or null.
*>
fn Type*? numeric(AnalyzerContext* context, String name) @local
{
	Type* t = lookup::get_type_by_name(context.lookup, name)!;
	if (t.status != RESOLVED) return NOT_FOUND~;
	switch (t.kind)
	{
		case TYPE_I8: case TYPE_I16: case TYPE_I32: case TYPE_I64: case TYPE_I128:
		case TYPE_U8: case TYPE_U16: case TYPE_U32: case TYPE_U64: case TYPE_U128:
		case TYPE_F16: case TYPE_BF16: case TYPE_F32: case TYPE_F64: case TYPE_F128:
		case TYPE_SZ: case TYPE_USZ: case TYPE_IPTR: case TYPE_UPTR:
			return t;
		case TYPE_VOID: case TYPE_BOOL: case TYPE_STRUCT: case TYPE_UNION: case TYPE_BITSTRUCT: case TYPE_ENUM:
			return NOT_FOUND~;
	}
}

fn uint bits(Type* t) @local => BitSizes::from_ordinal(t.data.builtin.bitsize).bits;


fn bool is_signed(Type* t) @local => (t.kind >= TYPE_I8 && t.kind <= TYPE_I128) || t.kind == TYPE_SZ || t.kind == TYPE_IPTR;

<*
 The wider of two numeric types: floats over integers, more bits over fewer,
 and between signed and unsigned of equal size the unsigned one.
*>
fn Type* wider(Type* a, Type* b) @local
{
	if (a.is_float() || b.is_float())
	{
		if (a.is_float() && b.is_float()) return bits(a) >= bits(b) ? a : b;
		return a.is_float() ? a : b;
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
	Type*? t = numeric(context, type);
	if (catch t) return type;
	if (t.is_float()) return bits(t) < 32 ? "float" : type;
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
			if (Node* method = operator_method(context, sf, t, kind, loc: loc).method) return instance_type(context, sf, t, method, return_type(method)) ?? "";
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
 Generic arguments `receiver` gives the type declaring `member`.
 Typedefs, aliases and inline members are followed from `receiver` to that type.
*>
fn GenericBinding member_binding(AnalyzerContext* context, SourceFile* sf, String receiver, Node* member)
{
	String current = receiver;
	for (int depth = 0; depth < MAX_ALIAS_DEPTH && current.len; depth++)
	{
		String base = generic_base(current);
		Node*? decl = find_type_node_in_context(context, sf, base) ?? find_type_node_in_context(context, null, base);
		if (catch decl) break;
		NullableGenerics params = ast::@nullable(generic_params(context, decl));
		String[] args = generic_args(current);
		Node*? member_receiver = receiver_type_expr(member);
		bool declared = @ok(member_receiver)
			? (cursor::raw_type_identifier(member_receiver) ?? "") == base
			: decl.range.contains_range(member.range) && ((source_file::file_of(context, decl) == source_file::file_of(context, member)) ?? false);
		if (declared) return { params, args };
		Node*? inner = inner_type(decl);
		if (catch inner) break;
		current = substitute(cursor::instance_name(inner), params, args);
	}
	return {};
}

<*
 Generic arguments of the receiver for `member`, named by the member of an
 access at `loc`, as `push` in `list.push`; none elsewhere.
*>
fn GenericBinding member_binding_at(AnalyzerContext* context, SourceFile* sf, Location loc, Node* member)
{
	Node*? node = node_at(sf, loc);
	if (catch node) return {};
	List{Node*} stack = ancestors_of(sf, node);
	sz n = stack.len();
	if (n < 2 || stack[n - 2].kind != ACCESS_EXPR) return {};
	AccessExpr* access = stack[n - 2].as(AccessExpr);
	if (!access.member.is(node) || access.left.kind == TYPE_EXPR) return {};
	String receiver = type_of(context, sf, access.left, loc);
	return receiver.len ? member_binding(context, sf, receiver, member) : {};
}

<*
 `type_expr`, declared by `member` of the type `receiver`, with the generic
 parameters of the type declaring `member` bound to the receiver's arguments.
*>
fn String instance_type(AnalyzerContext* context, SourceFile* sf, String receiver, Node* member, Node* type_expr) @local
{
	return bound_type(context, sf, cursor::instance_name(type_expr), member_binding(context, sf, receiver, member));
}

<*
 Type whose members `decl` exposes as its own: an inline member's, a typedef's
 or an alias's. Null when there is none.
*>
fn Node*? inner_type(Node* decl) @local
{
	switch (decl.kind)
	{
		case TYPEDEF_DECL:
			return decl.as(TypedefDecl).base_type.get();
		case ALIAS_DECL:
			Node* target = decl.as(AliasDecl).target.get()!;
			return target.kind == TYPE_EXPR ? target : NOT_FOUND~;
		case STRUCT_DECL:
			foreach (f : decl.as(StructDecl).fields)
			{
				if (f && f.kind == VAR_DECL && f.as(VarDecl).var_flags.is_inline) return f.as(VarDecl).type.get();
			}
			return NOT_FOUND~;
		default:
			return NOT_FOUND~;
	}
}

<*
 Generic parameters of the top-level `decl`: its own, else its module section's.
*>
fn GenericDecl*? generic_params(AnalyzerContext* context, Node* decl) @private
{
	if (try own = generics_of(decl)) return own;
	SourceFile* sf = source_file::file_of(context, decl)!;
	GenericDecl*? section = NOT_FOUND~;
	foreach (stmt : sf.ast.statements)
	{
		if (stmt == decl) return section;
		if (stmt && stmt.kind == MODULE_DECL) section = generics_of(stmt);
	}
	return NOT_FOUND~;
}

<*
 `type` without pointer/optional markers and generic arguments: `List{int}*` is `List`.
*>
fn String bare_type_name(String type)
{
	String clean = type.trim_right("*&? \t");
	if (try idx = clean.index_of_char('{')) clean = clean[:idx].trim();
	return clean.trim_right("*&? \t");
}

<*
 `type` without its generic arguments: `Queue{Timer}` is `Queue`.
*>
fn String generic_base(String type) => type[:type.index_of_char('{') ?? type.len].trim();

<*
 Name the methods of `type` are indexed under: `std::List{int}[]*` is `List`.
*>
fn String method_key(String type)
{
	String t = type[:type.index_of_char('{') ?? type.len];
	t = t[:t.index_of_char('[') ?? t.len].trim_right("*&? \t");
	return t[(t.rindex_of("::") ?? -2) + 2..].trim();
}

<*
 Generic arguments of `type`: `Timer` and `false` of `Queue{Timer, false}`.
*>
fn String[] generic_args(String type) @private
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
 `type` with the generic parameters of `binding` bound to its arguments.
 A type declared under the same parameters and named without arguments, as `Box` inside `module box <Type>`,
 is that instance: `Box{args}`.
*>
fn String bound_type(AnalyzerContext* context, SourceFile* sf, String type, GenericBinding binding)
{
	String[] args = binding.args;
	String bound = substitute(type, binding.params, args);
	GenericDecl*? params = binding.params.get();
	if (catch params) return bound;
	if (!args.len || type.contains("{")) return bound;
	sz end = 0;
	while (end < type.len && (lexer::is_ident(type[end]) || type[end] == ':')) end++;
	String name = type[:end];
	Node*? decl = find_type_node_in_context(context, sf, name) ?? find_type_node_in_context(context, null, name);
	if (catch decl) return bound;
	if (try own = generic_params(context, decl) && own == params) return string::tformat("%s{%s}%s", name, string::join(tmem, args, ", "), type[end..]);
	return bound;
}

<*
 `type` with each identifier naming one of `params` replaced by its argument in `args`.
*>
fn String substitute(String type, NullableGenerics generics, String[] args)
{
	GenericDecl*? params = generics.get();
	if (catch params) return type;
	if (!args.len) return type;
	DString out;
	out.tinit();
	sz i = 0;
	while (i < type.len)
	{
		char quote = type[i];
		if (quote == '"' || quote == '\'' || quote == '`')
		{
			// Literals, as default values in a signature, are copied as written.
			sz end = i + 1;
			while (end < type.len && type[end] != quote) end += quote != '`' && type[end] == '\\' ? 2 : 1;
			end = min(end + 1, type.len);
			out.append(type[i:end - i]);
			i = end;
			continue;
		}
		sz start = i;
		while (i < type.len && lexer::is_ident(type[i])) i++;
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
fn Node*? find_enum_argument_value(AnalyzerContext* context, SourceFile* sf, EnumDecl* ed, String name, Location loc) @local
{
	foreach (variant : ed.variants)
	{
		Node*? values = variant.as(VarDecl).assoc_values.get();
		if (catch values) continue;
		if (values.kind != INITIALIZER_LIST_EXPR || !values.range.contains(loc)) continue;
		foreach (i, arg : values.as(InitializerListExpr).exprs)
		{
			if (!arg || !arg.range.contains(loc)) continue;
			if (i >= ed.assoc_params.len) return NOT_FOUND~;
			String type_name = cursor::raw_type_identifier(ed.assoc_params[i].as(VarDecl).type.get()) ?? "";
			Node* type_node = find_type_node_in_context(context, sf, type_name, loc)!;
			if (type_node.kind != ENUM_DECL) return NOT_FOUND~;
			foreach (value : type_node.as(EnumDecl).variants)
			{
				if (value.as(VarDecl).name.is(name)) return value;
			}
			return NOT_FOUND~;
		}
	}
	return NOT_FOUND~;
}

<*
 Top-level statement containing `loc`. A declaration's range covers its doc
 contract.
*>
fn Node*? enclosing_top_level(SourceFile* sf, Location loc)
{
	Node*[] stmts = sf.ast.statements.array_view();
	for (sz i = sort::binarysearch(stmts, (Node*)null, &starts_at_or_before, &loc) - 1; i >= 0; i--)
	{
		if (stmts[i]) return stmts[i].range.contains(loc) ? stmts[i] : NOT_FOUND~;
	}
	return NOT_FOUND~;
}

<*
 Never equal, so a binary search over statements ends after the last one starting at or before `loc`.
*>
fn int starts_at_or_before(Node* stmt, Node* unused, Location* loc) @local => !stmt || !loc.before(stmt.range.start) ? -1 : 1;

<*
 Parameter `name` of the callable `decl`, or null.
*>
fn Node*? find_param(AnalyzerContext* context, SourceFile* sf, Node* decl, String name) @local
{
	foreach (p : callable_params(context, sf, decl))
	{
		if (p && p.kind == VAR_DECL && p.as(VarDecl).name.is(name)) return p;
	}
	return NOT_FOUND~;
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
	HashMap{String, NullableNode} decl_by_name;
	NullableGenerics section_generics;
	NullableGenerics decl_generics;
	NullableGenerics receiver_generics;
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
		self.section_generics = ast::@nullable(generics_of(stmt));
	}
	self.decl_generics = ast::@nullable(generics_of(stmt));
	self.receiver_generics = ast::@nullable(generics_of(self.receiver_decl(stmt)));
}

<*
 Type declaration a method `stmt` is declared on, whose generic parameters
 the method can use, or null.
*>
fn Node*? TypeNameScope.receiver_decl(&self, Node* stmt)
{
	Node* receiver = receiver_type_expr(stmt)!;
	if (receiver.kind != TYPE_EXPR) return NOT_FOUND~;
	TypeExpr* te = receiver.as(TypeExpr);
	if (te.type_kind != TYPE_IDENTIFIER) return NOT_FOUND~;
	Ident* name = te.unresolved.name.get()!;
	return find_type_node_in_context(self.context, self.sf, name.text, name.range.start);
}

fn Node*? find_generic_param(GenericDecl* gd, String name) @local
{
	foreach (param : gd.params)
	{
		if (param && param.kind != ERROR && generic_param_name(param) == name) return param;
	}
	return NOT_FOUND~;
}

<*
 Declaration `name` refers to at its position: a generic parameter in
 scope, else the visible type declaration, else null.
*>
fn Node*? TypeNameScope.resolve(&self, Ident* name)
{
	if (try param = find_generic_param(self.decl_generics.get(), name.text) ?? find_generic_param(self.receiver_generics.get(), name.text) ?? find_generic_param(self.section_generics.get(), name.text)) return param;
	if (try cached = self.decl_by_name.get(name.text)) return cached.get();
	Node*? decl = find_type_node_in_context(self.context, self.sf, name.text, name.range.start);
	self.decl_by_name.set(name.text, ast::@nullable(decl));
	return decl;
}

<*
 Declaration the symbol at `loc` refers to; see `resolve_name` for `overloads`.
*>
fn Node*? resolve_symbol_at(AnalyzerContext* context, SourceFile* sf, Location loc, List{Node*}* overloads = null)
{
	if (!sf) return NOT_FOUND~;
	Range target_range = {.start = loc,.end = loc };
	Node* target_node = node_at(sf, loc)!;
	if (target_node.kind == ERROR) return NOT_FOUND~;

	switch (target_node.kind)
	{
		case INTERFACE_DECL:
		case MODULE_DECL:
		case FAULT_DECL:
		case FAULTDEF_DECL:
		case ATTRDEF_DECL:
			return target_node;
		case ATTRIBUTE_DECL:
			if (try name = target_node.as(AttributeDecl).name.get() && context)
			{
				String caller_mod = get_module_name_at_location(sf, loc);
				if (try def = find_attrmacro_in_scope(context, sf, name.text, caller_mod, loc)) return def;
			}
			return target_node;
		default:
			if (cursor::decl_name(target_node).range.contains(loc) ?? false) return target_node;
	}

	if (try label = label_of(target_node) && label.range.touches(loc)) return target_node;
	if (try label = jump_label(target_node) && label.range.touches(loc))
	{
		foreach (n : enclosing_labeled(sf, target_node.range.start))
		{
			if ((label_of(n).text ?? "") == label.text) return n;
		}
		return NOT_FOUND~;
	}

	if (target_node.kind == CONTRACT_PARAM)
	{
		Ident* ident = target_node.as(ContractParam).ident.get()!;
		return find_param(context, sf, enclosing_top_level(sf, loc), ident.text);
	}

	if (target_node.kind == NAMED_ARG_EXPR)
	{
		Ident* name = target_node.as(NamedArgExpr).name;
		List{Node*} stack = ancestors_of(sf, target_node);
		sz n = stack.len();
		if (!name || n < 2 || stack[n - 2].kind != CALL_EXPR) return NOT_FOUND~;
		Node* callee = call_target(context, sf, stack[n - 2].as(CallExpr)).decl;
		return callee ? find_param(context, sf, callee, name.text) : NOT_FOUND~;
	}

	if (target_node.kind == PATH_EXPR)
	{
		PathExpr* path_expr = target_node.as(PathExpr);
		String mod_name = path_expr.path.text.strip_suffix("::");
		if (context && mod_name.len > 0)
		{
			if (try mod = resolve_module_for_prefix(context, sf, loc, mod_name) && mod.module_decls.len() > 0)
			{
				return (Node*)mod.module_decls.get(0);
			}
		}
		return target_node;
	}

	bool is_designator;
	Node*? designated = resolve_designator_field(context, sf, target_node, &is_designator);
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
fn Node*? resolve_name(AnalyzerContext* context, SourceFile* sf, Node* target_node, AccessExpr* access, Location loc, List{Node*}* overloads = null)
{
	String symbol_name = "";
	if (target_node.kind == TYPE_EXPR)
	{
		symbol_name = cursor::raw_type_identifier(target_node) ?? "";
	}
	if (symbol_name.len == 0 && target_node.kind == IDENT_EXPR)
	{
		IdentExpr* ie = target_node.as(IdentExpr);
		symbol_name = ie.ident.text;
	}
	if (symbol_name.len == 0)
	{
		symbol_name = cursor::spelling(target_node, tmem);
	}
	symbol_name = symbol_name.trim_right("*&? \t");
	if (symbol_name.len == 0) return NOT_FOUND~;

	if (target_node.kind == TYPE_EXPR && constants::is_primitive(symbol_name)) return target_node;

	if (target_node.kind == IDENT_EXPR)
	{
		IdentExpr* ident_expr = target_node.as(IdentExpr);
		if (try path = ident_expr.path_expr.get())
		{
			PathExpr* pe = path.as(PathExpr);
			if (pe.range.contains(loc) && !(ident_expr.ident.range.contains(loc)))
			{
				String mod_path = pe.path.text.strip_suffix("::");
				if (context && mod_path.len > 0)
				{
					if (try mod = resolve_module_for_prefix(context, sf, loc, mod_path) && mod.module_decls.len() > 0)
					{
						return (Node*)mod.module_decls.get(0);
					}
				}
				return NOT_FOUND~;
			}

			String mod_name = pe.path.text.strip_suffix("::");
			if (try mod = resolve_module_for_prefix(context, sf, loc, mod_name, symbol_name))
			{
				return find_symbol_in_module(context, mod, symbol_name, sf, loc);
			}
			return NOT_FOUND~;
		}
	}

	if (access)
	{
		AccessExpr* acc = access;
		String receiver_type = type_of(context, sf, acc.left, loc);

		if (receiver_type.len > 0)
		{
			if (try mnode = find_method_in_type(context, receiver_type, symbol_name, sf, loc, overloads)) return mnode;

			if (try field = find_member_in_type(context, receiver_type, symbol_name, sf, loc)) return field;
		}

		return NOT_FOUND~;
	}

	Node*? enclosing_decl = enclosing_top_level(sf, loc);
	if (try enclosing_decl && enclosing_decl.kind == ENUM_DECL)
	{
		if (try value = find_enum_argument_value(context, sf, enclosing_decl.as(EnumDecl), symbol_name, loc)) return value;
	}

	foreach (param : generic_params_at(context, sf, loc))
	{
		if (generic_param_name(param) == symbol_name) return param;
	}

	if (!symbol_name.starts_with("@"))
	{
		if (try enclosing_decl)
		{
			LocalSearchContext loc_search = {.context = context,.sf = sf,.name = symbol_name,.found_decl = null,.found_type = "", .loc = loc };
			cursor::visit(enclosing_decl, null, {.on_enter = &find_local_decl_callback }, &loc_search);
			if (loc_search.found_decl) return loc_search.found_decl;
		}
		else if (try local_decl = find_local_decl_in_file(sf, symbol_name, null, context))
		{
			return local_decl;
		}
	}

	if (target_node.kind == TYPE_EXPR)
	{
		if (try ty_node = find_type_node_in_context(context, sf, symbol_name, loc)) return ty_node;
	}

	if (context && context.registry)
	{
		if (try accessible = @first_accessible(context, sf, loc, context.registry.types.get(symbol_name) ?? (TypeInfo*)null)) return accessible;

		String caller_mod = get_module_name_at_location(sf, loc);
		if (try c = find_callable_in_scope(context, sf, symbol_name, caller_mod, loc)) return c;

		List{String} imports = get_imported_modules_at_location(sf, loc);
		foreach (imp : imports)
		{
			String imp_qname = string::tformat("%s::%s", imp, symbol_name);
			if (try accessible = @first_accessible(context, sf, loc, context.registry.types.get(imp_qname) ?? (TypeInfo*)null)) return accessible;
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
					if (try gd = generics_of((Node*)md))
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

					if (try gd = generics_of(node))
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

	if (try sym = find_symbol_in_context(context, sf, symbol_name, loc))
	{
		return sym;
	}

	return NOT_FOUND~;
}

fn Node*? resolve_callee_by_name(AnalyzerContext* context, SourceFile* sf, String callee_name, Location loc = { -1, -1 })
{
	if (!context || callee_name.len == 0) return NOT_FOUND~;

	String caller_mod = caller_module(sf, loc);

	if (try idx = callee_name.rindex_of("::"))
	{
		String mod_name = callee_name[:idx];
		String fn_name = callee_name[idx + 2..];

		return find_callable_in_module(context, resolve_module_for_prefix(context, sf, loc, mod_name, fn_name), fn_name, sf, loc);
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