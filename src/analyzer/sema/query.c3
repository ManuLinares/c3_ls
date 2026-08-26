module analyzer::sema::query;

import analyzer::core;
import analyzer::cursor;
import analyzer::lexer;
import analyzer::core::constants;

import std::collections::list;
import std::collections::map;
import std::io;

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
						ctx.found_type = cursor::raw_type_identifier(vd.type) ?? "";
					}
					return BREAK;
				}
			}
		case TRY_EXPR:
			{
				TryExpr* te = c.as(TryExpr);
				if (te.variable && te.variable.kind == IDENT_EXPR)
				{
					IdentExpr* ie = te.variable.as(IdentExpr);
					if (ie.ident && ie.ident.text == ctx.name)
					{
						ctx.found_decl = c;
						if (te.type)
						{
							ctx.found_type = cursor::raw_type_identifier(te.type) ?? "";
						}
						return BREAK;
					}
				}
			}
		case CATCH_EXPR:
			{
				CatchExpr* ce = c.as(CatchExpr);
				if (ce.variable && ce.variable.kind == IDENT_EXPR)
				{
					IdentExpr* ie = ce.variable.as(IdentExpr);
					if (ie.ident && ie.ident.text == ctx.name)
					{
						ctx.found_decl = c;
						if (ce.type)
						{
							ctx.found_type = cursor::raw_type_identifier(ce.type) ?? "";
						}
						return BREAK;
					}
				}
			}
		case FOREACH_STMT:
			{
				ForeachStmt* fst = c.as(ForeachStmt);
				if (fst.index && fst.index.kind == VAR_DECL)
				{
					VarDecl* ivd = fst.index.as(VarDecl);
					if (ivd.name && ivd.name.text == ctx.name)
					{
						ctx.found_decl = fst.index;
						ctx.found_type = "sz";
						return BREAK;
					}
				}
				if (fst.variable && fst.variable.kind == VAR_DECL)
				{
					VarDecl* vvd = fst.variable.as(VarDecl);
					if (vvd.name && vvd.name.text == ctx.name)
					{
						ctx.found_decl = fst.variable;
						if (vvd.type)
						{
							ctx.found_type = cursor::raw_type_identifier(vvd.type) ?? "";
						}
						else if (fst.enumeration)
						{
							String enum_type = get_type_of_expr(ctx.context, ctx.sf, fst.enumeration);
							if (enum_type.len > 0)
							{
								if (try idx = enum_type.index_of_char('['))
								{
									enum_type = enum_type[:idx];
								}
								else if (try idx = enum_type.index_of_char('{'))
								{
									enum_type = enum_type[idx + 1..].strip_suffix("}");
								}
								ctx.found_type = enum_type;
							}
						}
						return BREAK;
					}
				}
			}
		default:
			break;
	}

	return RECURSE;
}

fn Node* find_local_decl_in_file(SourceFile* sf, String name, String* out_type = null, AnalyzerContext* context = null)
{
	if (!sf || name.len == 0) return null;
	LocalSearchContext loc_search = {.context = context,.sf = sf,.name = name,.found_decl = null,.found_type = "" };
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		cursor::visit(stmt, null, {.on_enter = &find_local_decl_callback }, &loc_search);
		if (loc_search.found_decl)
		{
			if (out_type) * out_type = loc_search.found_type;
			return loc_search.found_decl;
		}
	}
	return null;
}

fn bool is_vector_type(String type_name)
{
	if (type_name.len == 0) return false;
	if (type_name == "Vec2" || type_name == "Vec3" || type_name == "Vec4") return true;
	return type_name.contains("[<") && type_name.contains(">]");
}

fn Node* find_method_in_type(AnalyzerContext* context, String type_name, String method_name)
{
	if (!context || type_name.len == 0 || method_name.len == 0) return null;

	String clean_mname = method_name.strip_prefix("@");

	String type_suffix = string::tformat("::%s", type_name);
	context.modules.@each(; mod_name, mod)
	{
		if (mod)
		{
			foreach (node : mod.nodes)
			{
				if (!node || node.kind == ERROR) continue;
				if (node.kind == FN_DECL)
				{
					FnDecl* fd = node.as(FnDecl);
					if (fd.name && fd.name.text.strip_prefix("@") == clean_mname && fd.associated_type)
					{
						String assoc = cursor::raw_type_identifier(fd.associated_type) ?? "";
						if (assoc == type_name || assoc.ends_with(type_suffix)) return node;
					}
				}
				else if (node.kind == MACRO_DECL)
				{
					MacroDecl* md = node.as(MacroDecl);
					if (md.name && md.name.text.strip_prefix("@") == clean_mname)
					{
						if (try assoc_node = md.associated_type.get())
						{
							String assoc = cursor::raw_type_identifier(assoc_node) ?? "";
							if (assoc == type_name || assoc.ends_with(type_suffix)) return node;
						}
					}
				}
			}
		}
	};

	TypeInfo* ty_info = null;
	if (context.registry)
	{
		ty_info = context.registry.types.get(type_name) ?? null;
		if (!ty_info)
		{
			context.registry.types.@each(; qname, tinfo)
			{
				if (!ty_info && (qname == type_name || qname.ends_with(type_suffix)))
				{
					ty_info = tinfo;
				}
			};
		}
	}
	Node* type_node = ty_info ? ty_info.node : null;

	if (!type_node)
	{
		context.modules.@each(; mod_name, mod)
		{
			if (!type_node && mod)
			{
				foreach (node : mod.nodes)
				{
					if (!node || node.kind == ERROR) continue;
					String sname = cursor::spelling(node, tmem);
					if (sname == type_name)
					{
						type_node = node;
						break;
					}
				}
			}
		};
	}

	if (type_node)
	{
		switch (type_node.kind)
		{
			case STRUCT_DECL:
				{
					StructDecl* sd = type_node.as(StructDecl);
					foreach (inter : sd.interfaces)
					{
						String sub_type = cursor::raw_type_identifier(inter) ?? "";
						if (sub_type.len > 0 && sub_type != type_name)
						{
							Node* m = find_method_in_type(context, sub_type, method_name);
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
							if (sub_type.len > 0 && sub_type != type_name)
							{
								Node* m = find_method_in_type(context, sub_type, method_name);
								if (m) return m;
							}
						}
					}
				}
			case TYPEDEF_DECL:
				{
					TypedefDecl* td = type_node.as(TypedefDecl);
					if (td.is_inline && td.base_type)
					{
						String base_type = cursor::raw_type_identifier(td.base_type) ?? "";
						if (base_type.len > 0 && base_type != type_name)
						{
							Node* m = find_method_in_type(context, base_type, method_name);
							if (m) return m;
						}
					}
				}
			default:
				break;
		}
	}

	return null;
}

fn Node* find_member_in_type(AnalyzerContext* context, String type_name, String member_name)
{
	if (!context || type_name.len == 0 || member_name.len == 0) return null;

	TypeInfo* ty_info = null;
	if (context.registry)
	{
		ty_info = context.registry.types.get(type_name) ?? null;
		if (!ty_info)
		{
			String suffix = string::tformat("::%s", type_name);
			context.registry.types.@each(; qname, tinfo)
			{
				if (!ty_info && (qname == type_name || qname.ends_with(suffix)))
				{
					ty_info = tinfo;
				}
			};
		}
	}
	Node* type_node = ty_info ? ty_info.node : null;

	if (!type_node)
	{
		context.modules.@each(; mod_name, mod)
		{
			if (!type_node && mod)
			{
				foreach (node : mod.nodes)
				{
					if (!node || node.kind == ERROR) continue;
					String sname = cursor::spelling(node, tmem);
					if (sname == type_name)
					{
						type_node = node;
						break;
					}
				}
			}
		};
	}

	if (type_node)
	{
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
					Node* res = find_member_in_type(context, sub_type, member_name);
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
						Node* res = find_member_in_type(context, sub_type, member_name);
						if (res) return res;
					}
				}
			}
		}
	}

	return null;
}

fn String get_type_of_expr(AnalyzerContext* context, SourceFile* sf, Node* expr)
{
	if (!expr || expr.kind == ERROR) return "";

	switch (expr.kind)
	{
		case TYPE_EXPR:
			return cursor::raw_type_identifier(expr) ?? "";

		case UNARY_EXPR:
			{
				UnaryExpr* ue = expr.as(UnaryExpr);
				return get_type_of_expr(context, sf, ue.expr);
			}

		case POST_UNARY_EXPR:
			{
				PostUnaryExpr* pue = expr.as(PostUnaryExpr);
				return get_type_of_expr(context, sf, pue.unary.expr);
			}

		case DESIGNATOR_EXPR:
			{
				DesignatorExpr* des = expr.as(DesignatorExpr);
				return get_type_of_expr(context, sf, des.path);
			}

		case MAYBE_DEREF_EXPR:
			{
				MaybeDerefExpr* deref = expr.as(MaybeDerefExpr);
				return get_type_of_expr(context, sf, deref.left);
			}

		case IDENT_EXPR:
			{
				IdentExpr* ident = expr.as(IdentExpr);
				String id_name = ident.ident ? ident.ident.text : "";
				if (id_name.len == 0) return "";

				if (ident.path_expr && ident.path_expr.kind == PATH_EXPR)
				{
					String mod_name = ident.path_expr.as(PathExpr).path ? ident.path_expr.as(PathExpr).path.text.strip_suffix("::") : "";
					Module* mod = context ? (context.modules.get(mod_name) ?? null) : null;
					if (!mod && context)
					{
						String suffix = string::tformat("::%s", mod_name);
						context.modules.@each(; mname, m)
						{
							if (!mod && (mname == mod_name || mname.ends_with(suffix)))
							{
								mod = m;
							}
						};
					}

					if (mod)
					{
						foreach (stmt : mod.nodes)
						{
							if (!stmt || stmt.kind == ERROR) continue;
							switch (stmt.kind)
							{
							case VAR_DECL:
								{
									VarDecl* vd = stmt.as(VarDecl);
									if (vd.name && vd.name.text == id_name && vd.type)
									{
										return cursor::raw_type_identifier(vd.type) ?? "";
									}
								}
							case STRUCT_DECL:
							case ENUM_DECL:
							case TYPEDEF_DECL:
								{
									String sname = cursor::spelling(stmt, tmem);
									if (sname == id_name) return id_name;
								}
							default:
								break;
						}
					}
				}
			}

			String local_type;
			if (sf && find_local_decl_in_file(sf, id_name, &local_type, context))
			{
				if (local_type.len > 0) return local_type;
			}

			if (context && context.registry)
			{
				if (try ty_info = context.registry.types.get(id_name))
				{
					return id_name;
				}
			}

			return id_name;
		}

		case ACCESS_EXPR:
			{
				AccessExpr* acc = expr.as(AccessExpr);
				String parent_type = get_type_of_expr(context, sf, acc.left);
				if (parent_type.len == 0) return "";

				String mem_name = cursor::spelling(acc.member, tmem);
				if (mem_name.len == 0) return "";

				Node* member = find_member_in_type(context, parent_type, mem_name);
				if (member && member.kind == VAR_DECL)
				{
					VarDecl* vd = member.as(VarDecl);
					if (vd.type) return cursor::raw_type_identifier(vd.type) ?? "";
				}

				Node* mnode = find_method_in_type(context, parent_type, mem_name);
				if (mnode && mnode.kind == FN_DECL)
				{
					FnDecl* fd = mnode.as(FnDecl);
					if (fd.ret_type) return cursor::raw_type_identifier(fd.ret_type) ?? "";
				}
				return "";
			}

		case CALL_EXPR:
			{
				CallExpr* call = expr.as(CallExpr);
				if (!call.callee) return "";

				switch (call.callee.kind)
				{
				case ACCESS_EXPR:
					{
						AccessExpr* acc = call.callee.as(AccessExpr);
						String parent_type = get_type_of_expr(context, sf, acc.left);
						String method_name = cursor::spelling(acc.member, tmem);
						if (parent_type.len > 0 && method_name.len > 0)
						{
							Node* mnode = find_method_in_type(context, parent_type, method_name);
							if (mnode && mnode.kind == FN_DECL)
							{
								FnDecl* fd = mnode.as(FnDecl);
								if (fd.ret_type) return cursor::raw_type_identifier(fd.ret_type) ?? "";
							}
						}
					}
				case IDENT_EXPR:
					{
						String fn_name = cursor::spelling(call.callee, tmem);
						if (context && context.registry)
						{
							if (try fn_info = context.registry.functions.get(fn_name))
							{
								if (fn_info.node && fn_info.node.kind == FN_DECL)
								{
									FnDecl* fd = fn_info.node.as(FnDecl);
									if (fd.ret_type) return cursor::raw_type_identifier(fd.ret_type) ?? "";
								}
							}
						}
					}
				default:
					break;
			}
			return "";
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

fn Node* resolve_symbol_at(AnalyzerContext* context, SourceFile* sf, Location loc)
{
	if (!sf) return null;
	Range target_range = {.start = loc,.end = loc };
	Node* target_node = cursor::find_at(sf.ast.statements.array_view(), target_range);
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
		case ATTRIBUTE_DECL:
		case MODULE_DECL:
		case FAULT_DECL:
		case FAULTDEF_DECL:
			return target_node;
		case VAR_DECL:
			{
				VarDecl* vd = target_node.as(VarDecl);
				if (vd.name && vd.name.range.contains(loc))
				{
					return target_node;
				}
			}
		default:
			break;
	}

	if (target_node.kind == PATH_EXPR)
	{
		PathExpr* path_expr = target_node.as(PathExpr);
		String mod_name = path_expr.path ? path_expr.path.text.strip_suffix("::") : "";
		if (context && mod_name.len > 0)
		{
			Module* mod = context.modules.get(mod_name) ?? null;
			if (!mod)
			{
				String suffix = string::tformat("::%s", mod_name);
				context.modules.@each(; mname, m)
				{
					if (!mod && (mname == mod_name || mname.ends_with(suffix)))
					{
						mod = m;
					}
				};
			}

			if (mod && mod.module_decls.len() > 0)
			{
				return (Node*)mod.module_decls.get(0);
			}
		}
		return target_node;
	}

	String symbol_name = cursor::spelling(target_node, tmem);
	if (symbol_name.len == 0 && target_node.kind == IDENT_EXPR)
	{
		IdentExpr* ie = target_node.as(IdentExpr);
		symbol_name = ie.ident ? ie.ident.text : "";
	}
	if (symbol_name.len == 0 && target_node.kind == TYPE_EXPR)
	{
		symbol_name = cursor::raw_type_identifier(target_node) ?? "";
	}
	if (symbol_name.len == 0) return null;

	if (target_node.kind == TYPE_EXPR && constants::is_primitive(symbol_name))
	{
		return target_node;
	}

	if (target_node.kind == IDENT_EXPR)
	{
		IdentExpr* ident_expr = target_node.as(IdentExpr);
		if (ident_expr.path_expr && ident_expr.path_expr.kind == PATH_EXPR)
		{
			String mod_name = ident_expr.path_expr.as(PathExpr).path ? ident_expr.path_expr.as(PathExpr).path.text.strip_suffix("::") : "";
			Module* mod = context.modules.get(mod_name) ?? null;
			if (!mod)
			{
				String suffix = string::tformat("::%s", mod_name);
				context.modules.@each(; mname, m)
				{
					if (!mod && (mname == mod_name || mname.ends_with(suffix)))
					{
						mod = m;
					}
				};
			}

			if (mod)
			{
				String qname = string::tformat("%s::%s", mod.name, symbol_name);
				if (context.registry)
				{
					if (try fn_info = context.registry.functions.get(qname))
					{
						return fn_info.node;
					}
					if (try mac_info = context.registry.macros.get(qname))
					{
						return mac_info.node;
					}
					if (try ty_info = context.registry.types.get(qname))
					{
						return ty_info.node;
					}
				}
				foreach (stmt : mod.nodes)
				{
					if (!stmt || stmt.kind == ERROR) continue;
					String sname = cursor::spelling(stmt, tmem);
					if (sname == symbol_name || sname.strip_prefix("@") == symbol_name.strip_prefix("@")) return stmt;
				}
			}
		}
	}

	AccessSearchContext acc_ctx = {.target_range = target_range,.found_access = null };
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		cursor::visit(stmt, null, {.on_enter = &find_access_callback }, &acc_ctx);
		if (acc_ctx.found_access) break;
	}

	if (acc_ctx.found_access && acc_ctx.found_access.kind == ACCESS_EXPR)
	{
		AccessExpr* acc = acc_ctx.found_access.as(AccessExpr);
		String receiver_type = get_type_of_expr(context, sf, acc.left);

		if (receiver_type.len > 0)
		{
			Node* mnode = find_method_in_type(context, receiver_type, symbol_name);
			if (mnode) return mnode;

			Node* field = find_member_in_type(context, receiver_type, symbol_name);
			if (field) return field;
		}

		return null;
	}

	if (!symbol_name.starts_with("@"))
	{
		Node* enclosing_func = null;
		foreach (stmt : sf.ast.statements)
		{
			if (stmt && stmt.range.contains(loc))
			{
				enclosing_func = stmt;
				break;
			}
		}

		Node* local_decl = null;
		if (enclosing_func)
		{
			LocalSearchContext loc_search = {.context = context,.sf = sf,.name = symbol_name,.found_decl = null,.found_type = "" };
			cursor::visit(enclosing_func, null, {.on_enter = &find_local_decl_callback }, &loc_search);
			local_decl = loc_search.found_decl;
		}
		else
		{
			local_decl = find_local_decl_in_file(sf, symbol_name, null, context);
		}

		if (local_decl) return local_decl;
	}

	if (context)
	{
		context.modules.@each(; mod_name, mod)
		{
			if (mod)
			{
				foreach (md : mod.module_decls)
				{
					if (md && md.generics && md.generics.kind == GENERIC_DECL)
					{
						GenericDecl* gd = md.generics.as(GenericDecl);
						foreach (param : gd.params)
						{
							if (!param || param.kind == ERROR) continue;
							String pname = cursor::spelling(param, tmem);
							if (pname.len == 0) pname = cursor::raw_type_identifier(param) ?? "";
							if (pname == symbol_name) return param;
						}
					}
				}

				foreach (node : mod.nodes)
				{
					if (!node || node.kind == ERROR) continue;
					GenericDecl* gd = null;
					switch (node.kind)
					{
						case STRUCT_DECL:
							if (node.as(StructDecl).generics && node.as(StructDecl).generics.kind == GENERIC_DECL)
							{
								gd = node.as(StructDecl).generics.as(GenericDecl);
							}
						case TYPEDEF_DECL:
							if (node.as(TypedefDecl).generics && node.as(TypedefDecl).generics.kind == GENERIC_DECL)
							{
								gd = node.as(TypedefDecl).generics.as(GenericDecl);
							}
						case ALIAS_DECL:
							if (node.as(AliasDecl).generics && node.as(AliasDecl).generics.kind == GENERIC_DECL)
							{
								gd = node.as(AliasDecl).generics.as(GenericDecl);
							}
						case FN_DECL:
							if (node.as(FnDecl).generics && node.as(FnDecl).generics.kind == GENERIC_DECL)
							{
								gd = node.as(FnDecl).generics.as(GenericDecl);
							}
						case MACRO_DECL:
							if (node.as(MacroDecl).generics && node.as(MacroDecl).generics.kind == GENERIC_DECL)
							{
								gd = node.as(MacroDecl).generics.as(GenericDecl);
							}
						default:
							break;
					}

					if (gd)
					{
						foreach (param : gd.params)
						{
							if (!param || param.kind == ERROR) continue;
							String pname = cursor::spelling(param, tmem);
							if (pname.len == 0) pname = cursor::raw_type_identifier(param) ?? "";
							if (pname == symbol_name) return param;
						}
					}
				}
			}
		};
	}

	if (context && context.registry)
	{
		if (try ty_info = context.registry.types.get(symbol_name))
		{
			if (ty_info.node) return ty_info.node;
		}
		if (try fn_info = context.registry.functions.get(symbol_name))
		{
			if (fn_info.node) return fn_info.node;
		}
		if (try mac_info = context.registry.macros.get(symbol_name))
		{
			if (mac_info.node) return mac_info.node;
		}

		String clean_name = symbol_name.strip_prefix("@");
		if (try mac_info = context.registry.macros.get(clean_name))
		{
			if (mac_info.node) return mac_info.node;
		}
	}

	if (context)
	{
		context.modules.@each(; mod_name, mod)
		{
			if (mod)
			{
				foreach (stmt : mod.nodes)
				{
					if (!stmt || stmt.kind == ERROR) continue;
					String sname = cursor::spelling(stmt, tmem);
					if (sname.len > 0 && (sname == symbol_name || sname.strip_prefix("@") == symbol_name.strip_prefix("@")))
					{
						return stmt;
					}

					switch (stmt.kind)
					{
						case FAULTDEF_DECL:
							{
								FaultdefDecl* fd = stmt.as(FaultdefDecl);
								foreach (fault_node : fd.faults)
								{
									if (!fault_node || fault_node.kind != FAULT_DECL) continue;
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
								StructDecl* sd = stmt.as(StructDecl);
								foreach (field : sd.fields)
								{
									if (!field || field.kind != VAR_DECL) continue;
									VarDecl* vd = field.as(VarDecl);
									if (vd.name && vd.name.text == symbol_name) return field;
								}
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

fn Node* resolve_callee_by_name(AnalyzerContext* context, SourceFile* sf, String callee_name)
{
	if (!context || callee_name.len == 0) return null;

	if (try idx = callee_name.index_of("::"))
	{
		String mod_name = callee_name[:idx];
		String fn_name = callee_name[idx + 2..];

		Module* mod = context.modules.get(mod_name) ?? null;
		if (!mod)
		{
			String suffix = string::tformat("::%s", mod_name);
			context.modules.@each(; mname, m)
			{
				if (!mod && (mname == mod_name || mname.ends_with(suffix)))
				{
					mod = m;
				}
			};
		}

		if (mod)
		{
			String qname = string::tformat("%s::%s", mod.name, fn_name);
			if (context.registry)
			{
				if (try fn_info = context.registry.functions.get(qname)) return fn_info.node;
				if (try mac_info = context.registry.macros.get(qname)) return mac_info.node;
			}
			foreach (stmt : mod.nodes)
			{
				if (!stmt || stmt.kind == ERROR) continue;
				String sname = cursor::spelling(stmt, tmem);
				if (sname == fn_name || sname.strip_prefix("@") == fn_name.strip_prefix("@")) return stmt;
			}
		}
	}

	if (try dot_idx = callee_name.index_of_char('.'))
	{
		String recv_name = callee_name[:dot_idx];
		String method_name = callee_name[dot_idx + 1..];

		Node* mnode = find_method_in_type(context, recv_name, method_name);
		if (mnode) return mnode;

		String recv_type = "";
		if (sf)
		{
			(void)find_local_decl_in_file(sf, recv_name, &recv_type, context);
		}

		if (recv_type.len > 0)
		{
			mnode = find_method_in_type(context, recv_type, method_name);
			if (mnode) return mnode;
		}
	}

	if (context.registry)
	{
		if (try fn_info = context.registry.functions.get(callee_name)) return fn_info.node;
		if (try mac_info = context.registry.macros.get(callee_name)) return mac_info.node;

		String clean_name = callee_name.strip_prefix("@");
		if (try mac_info = context.registry.macros.get(clean_name)) return mac_info.node;
	}

	context.modules.@each(; mod_name, mod)
	{
		if (mod)
		{
			foreach (stmt : mod.nodes)
			{
				if (!stmt || stmt.kind == ERROR) continue;
				String sname = cursor::spelling(stmt, tmem);
				if (sname == callee_name || sname.strip_prefix("@") == callee_name.strip_prefix("@")) return stmt;
			}
		}
	};

	return null;
}
