module lsp::analysis::hover;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema::query;
import lsp::analysis::macro_expand;

import std::collections::list;
import std::collections::map;
import std::io;

import lsp::core;
import lsp;
import uri;
import lsp::analysis;

struct CallFinderContext
{
	Range target_range;
	CallExpr* found_call;
}

fn ChildVisitResult find_call_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	CallFinderContext* ctx = (CallFinderContext*)user_data;
	if (c.kind == CALL_EXPR && c.range.contains_range(ctx.target_range))
	{
		ctx.found_call = c.as(CallExpr);
		return RECURSE;
	}
	return RECURSE;
}

struct AccessFinderContext
{
	Range target_range;
	AccessExpr* found_access;
}

fn ChildVisitResult find_enclosing_access_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	AccessFinderContext* ctx = (AccessFinderContext*)user_data;
	if (c.kind == ACCESS_EXPR && c.range.contains_range(ctx.target_range))
	{
		ctx.found_access = c.as(AccessExpr);
		return RECURSE;
	}
	return RECURSE;
}

fn String format_param_signature(Node* param)
{
	if (!param || param.kind != VAR_DECL) return "";
	VarDecl* pdecl = param.as(VarDecl);

	DString buf;
	buf.tinit();

	if (pdecl.type)
	{
		String ptype = cursor::spelling(pdecl.type, tmem);
		if (ptype.len > 0)
		{
			buf.append(ptype);
			buf.append(" ");
		}
	}

	String pname = pdecl.name ? pdecl.name.text : (pdecl.var_flags.is_variadic ? "..." : "");
	buf.append(pname);

	if (pdecl.init_expr)
	{
		String init_text = cursor::spelling(pdecl.init_expr, tmem);
		if (init_text.len == 0 && pdecl.init_expr.kind == LITERAL_EXPR)
		{
			LiteralExpr* lit = pdecl.init_expr.as(LiteralExpr);
			switch (lit.literal_kind)
			{
				case INT_LITERAL:
					init_text = string::tformat("%d", lit.integer);
				case REAL_LITERAL:
					if (lit.real == (double)(long)lit.real)
					{
						init_text = string::tformat("%.1f", lit.real);
					}
					else
					{
						init_text = string::tformat("%g", lit.real);
					}
				case STRING_LITERAL:
					init_text = string::tformat("\"%s\"", lit.string);
				case BOOL_LITERAL:
					init_text = lit.boolean ? "true" : "false";
				case NULL_LITERAL:
					init_text = "null";
				default:
					break;
			}
		}
		if (init_text.len > 0)
		{
			buf.appendf(" = %s", init_text);
		}
	}

	return buf.str_view();
}

fn String format_node_signature(Node* node, String name)
{
	if (!node) return name;
	DString buf;
	buf.tinit();

	switch (node.kind)
	{
		case PATH_EXPR:
			{
				PathExpr* pe = node.as(PathExpr);
				String mod_name = pe.path ? pe.path.text.strip_suffix("::") : name;
				buf.appendf("module %s;", mod_name);
			}
		case MODULE_DECL:
			{
				ModuleDecl* mod_decl = node.as(ModuleDecl);
				String mod_name = mod_decl.path ? mod_decl.path.as(PathExpr).path.text : name;
				buf.appendf("module %s;", mod_name);
			}
		case FN_DECL:
			{
				FnDecl* fn_decl = node.as(FnDecl);
				String ret = cursor::spelling(fn_decl.ret_type, tmem) ?: "void";
				if (fn_decl.associated_type)
				{
					String assoc = cursor::spelling(fn_decl.associated_type, tmem);
					buf.appendf("fn %s %s.%s(", ret, assoc, name);
				}
				else
				{
					buf.appendf("fn %s %s(", ret, name);
				}
				foreach (i, param : fn_decl.params)
				{
					if (i > 0) buf.append(", ");
					buf.append(format_param_signature(param));
				}
				buf.append(")");
			}
		case MACRO_DECL:
			{
				MacroDecl* mac = node.as(MacroDecl);
				String ret = "";
				if (try ret_node = mac.ret_type.get())
				{
					ret = cursor::spelling(ret_node, tmem);
				}

				if (try assoc = mac.associated_type.get())
				{
					String assoc_name = cursor::spelling(assoc, tmem);
					if (ret.len > 0 && ret != "void")
					{
						buf.appendf("macro %s %s.%s(", ret, assoc_name, name);
					}
					else
					{
						buf.appendf("macro %s.%s(", assoc_name, name);
					}
				}
				else
				{
					if (ret.len > 0 && ret != "void")
					{
						buf.appendf("macro %s %s(", ret, name);
					}
					else
					{
						buf.appendf("macro %s(", name);
					}
				}
				foreach (i, param : mac.params)
				{
					if (i > 0) buf.append(", ");
					buf.append(format_param_signature(param));
				}
				if (mac.body_params && mac.body_params.kind == BODY_PARAM_DECL)
				{
					BodyParamDecl* bpd = mac.body_params.as(BodyParamDecl);
					buf.append("; @body(");
					foreach (i, bp : bpd.params)
					{
						if (i > 0) buf.append(", ");
						buf.append(format_param_signature(bp));
					}
					buf.append(")");
				}
				buf.append(")");
			}
		case STRUCT_DECL:
			{
				StructDecl* st = node.as(StructDecl);
				if (st.is_union)
				{
					buf.appendf("union %s", name);
				}
				else if (st.is_bitstruct)
				{
					buf.appendf("bitstruct %s", name);
				}
				else
				{
					buf.appendf("struct %s", name);
				}
			}
		case ENUM_DECL:
			buf.appendf("enum %s", name);
		case TYPEDEF_DECL:
			{
				TypedefDecl* td = node.as(TypedefDecl);
				String base = cursor::spelling(td.base_type, tmem);
				buf.appendf("typedef %s = %s", name, base);
			}
		case ALIAS_DECL:
			{
				AliasDecl* ad = node.as(AliasDecl);
				String target = cursor::spelling(ad.target, tmem);
				buf.appendf("alias %s = %s", name, target);
			}
		case VAR_DECL:
			{
				VarDecl* vd = node.as(VarDecl);
				String vtype = cursor::spelling(vd.type, tmem) ?: "var";
				if (vd.var_flags.is_const)
				{
					buf.appendf("const %s %s", vtype, name);
				}
				else
				{
					buf.appendf("%s %s", vtype, name);
				}
			}
		case TYPE_EXPR:
			{
				buf.appendf("type %s", name);
			}
		case TRY_EXPR:
			{
				TryExpr* te = node.as(TryExpr);
				String vtype = cursor::spelling(te.type, tmem) ?: "var";
				buf.appendf("try %s %s", vtype, name);
			}
		case CATCH_EXPR:
			{
				CatchExpr* ce = node.as(CatchExpr);
				String vtype = cursor::spelling(ce.type, tmem) ?: "catch";
				buf.appendf("catch %s %s", vtype, name);
			}
		case FAULT_DECL:
			{
				buf.appendf("fault %s", name);
			}
		case FAULTDEF_DECL:
			{
				buf.appendf("faultdef %s", name);
			}
		default:
			buf.append(name);
	}

	return buf.str_view();
}

fn String? hover(LspProject* project, Uri uri, LspPosition pos)
{
	Location loc = {
		.line = (int)pos.line,
		.column = (int)pos.character
	};

	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf || !project.workspace.ctx) return "";

	Range target_range = {.start = loc,.end = loc };
	Node* target_node = cursor::find_at(sf.ast.statements.array_view(), target_range);

	AccessFinderContext acc_finder = {.target_range = target_range,.found_access = null };
	CallFinderContext call_finder = {.target_range = target_range,.found_call = null };
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		cursor::visit(stmt, null, {.on_enter = &find_enclosing_access_callback }, &acc_finder);
		cursor::visit(stmt, null, {.on_enter = &find_call_callback }, &call_finder);
	}

	Node* ct_node = acc_finder.found_access ? (Node*)acc_finder.found_access : (call_finder.found_call ? (Node*)call_finder.found_call : target_node);
	if (ct_node)
	{
		String ct_eval = macro_expand::evaluate_compile_time(project.workspace.ctx, sf, ct_node);
		if (ct_eval.len > 0)
		{
			DString ct_buf;
			ct_buf.tinit();
			ct_buf.appendf("```c3\n// Compile-Time Evaluation:\n%s\n```", ct_eval);
			return ct_buf.str_view();
		}
	}

	Node* decl_node = query::resolve_symbol_at(project.workspace.ctx, sf, loc);
	if (!decl_node) return "";

	String symbol_name = analysis::get_node_symbol_name(decl_node);
	if (symbol_name.len == 0 && decl_node.kind != MODULE_DECL && decl_node.kind != PATH_EXPR) return "";

	String signature = format_node_signature(decl_node, symbol_name);
	String doc_comment = cursor::docs(decl_node) ?? "";

	DString md_buf;
	md_buf.tinit();
	md_buf.appendf("```c3\n%s\n```", signature);

	if (decl_node.kind == MACRO_DECL)
	{
		CallFinderContext call_ctx = {.target_range = target_range,.found_call = null };
		foreach (stmt : sf.ast.statements)
		{
			if (!stmt || stmt.kind == ERROR) continue;
			cursor::visit(stmt, null, {.on_enter = &find_call_callback }, &call_ctx);
			if (call_ctx.found_call) break;
		}

		if (call_ctx.found_call)
		{
			String expansion = macro_expand::expand_macro(project.workspace.ctx, sf, call_ctx.found_call, decl_node.as(MacroDecl));
			String trimmed_expansion = expansion.trim();
			if (trimmed_expansion.len > 0 && trimmed_expansion != "{}" && trimmed_expansion != "{\n}")
			{
				md_buf.appendf("\n\n**Macro Expansion:**\n```c3\n%s\n```", expansion);
			}
		}
	}

	if (doc_comment.len > 0)
	{
		String clean_doc = doc_comment.trim().treplace("\"", "");
		if (clean_doc.len > 0)
		{
			md_buf.appendf("\n\n%s", clean_doc);
		}
	}

	return md_buf.str_view();
}
