module lsp::analysis::inlay_hints;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema::query;

import std::collections::list;
import std::collections::map;
import std::io;

import lsp::core;
import lsp;
import uri;

struct InlayHintCollector
{
	LspProject* project;
	SourceFile* sf;
	String caller_mod;
	String current_assoc_type;
	LspRange range;
	List{InlayHint} * hints;
	HashMap{String, String} local_types;
}

fn Node* resolve_inlay_callee(InlayHintCollector* ctx, CallExpr* call)
{
	if (!call || !call.callee) return null;
	if (!ctx.project.workspace.ctx) return null;
	AnalyzerContext* actx = ctx.project.workspace.ctx;

	switch (call.callee.kind)
	{
		case IDENT_EXPR:
			{
				IdentExpr* ie = call.callee.as(IdentExpr);
				String iname = ie.ident ? ie.ident.text : "";
				if (iname.len == 0) return null;

				if (ie.path_expr && ie.path_expr.kind == PATH_EXPR)
				{
					String ptext = ie.path_expr.as(PathExpr).path ? ie.path_expr.as(PathExpr).path.text : "";
					String qname = string::tformat("%s%s", ptext, iname);
					if (actx.registry)
					{
						if (try fn_info = actx.registry.functions.get(qname))
						{
							if (fn_info && fn_info.node) return fn_info.node;
						}
						if (try mac_info = actx.registry.macros.get(qname))
						{
							if (mac_info && mac_info.node) return mac_info.node;
						}
					}
				}
				else
				{
					if (ctx.caller_mod.len > 0 && actx.registry)
					{
						String local_qname = string::tformat("%s::%s", ctx.caller_mod, iname);
						if (try fn_info = actx.registry.functions.get(local_qname))
						{
							if (fn_info && fn_info.node) return fn_info.node;
						}
						if (try mac_info = actx.registry.macros.get(local_qname))
						{
							if (mac_info && mac_info.node) return mac_info.node;
						}
					}

					if (actx.registry)
					{
						if (try fn_info = actx.registry.functions.get(iname))
						{
							if (fn_info && fn_info.node) return fn_info.node;
						}
						if (try mac_info = actx.registry.macros.get(iname))
						{
							if (mac_info && mac_info.node) return mac_info.node;
						}
					}
				}
				return query::resolve_callee_by_name(actx, ctx.sf, iname);
			}

		case ACCESS_EXPR:
			{
				AccessExpr* acc = call.callee.as(AccessExpr);
				String recv_name = cursor::spelling(acc.left, tmem);
				String member_name = cursor::spelling(acc.member, tmem);
				if (recv_name.len == 0 || member_name.len == 0) return null;

				String recv_type = ctx.local_types.get(recv_name) ?? "";
				if (recv_type.len > 0)
				{
					Node* mnode = query::find_method_in_type(actx, recv_type, member_name, ctx.sf);
					if (mnode) return mnode;
				}

				String full_name = string::tformat("%s.%s", recv_name, member_name);
				return query::resolve_callee_by_name(actx, ctx.sf, full_name);
			}

		default:
			return null;
	}
}

fn ChildVisitResult collect_inlay_hints_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	InlayHintCollector* ctx = (InlayHintCollector*)user_data;
	if (!ctx) return CONTINUE;

	if (c.range.end.line < (int)ctx.range.start.line || c.range.start.line > (int)ctx.range.end.line)
	{
		return CONTINUE;
	}

	switch (c.kind)
	{
		case MODULE_DECL:
		case IMPORT_DECL:
		case ATTRDEF_DECL:
		case FAULTDEF_DECL:
		case FAULT_DECL:
		case TYPEDEF_DECL:
		case ALIAS_DECL:
		case ENUM_DECL:
		case STRUCT_DECL:
		case INTERFACE_DECL:
		case LITERAL_EXPR:
		case IDENT_EXPR:
		case PATH_EXPR:
		case BUILTIN_EXPR:
		case COMPILER_CONST_EXPR:
		case CONTINUE_BREAK_STMT:
		case NEXTCASE_STMT:
		case NOP_STMT:
			return CONTINUE;

		case FN_DECL:
			{
				FnDecl* fd = c.as(FnDecl);
				if (fd.associated_type)
				{
					ctx.current_assoc_type = cursor::spelling(fd.associated_type, tmem);
				}
				foreach (param : fd.params)
				{
					if (!param || param.kind != VAR_DECL) continue;
					VarDecl* vd = param.as(VarDecl);
					if (vd.name && vd.type)
					{
						String tname = cursor::spelling(vd.type, tmem);
						if (tname.len > 0) ctx.local_types.set(vd.name.text, tname);
					}
					else if (vd.name && vd.var_flags.is_self && ctx.current_assoc_type.len > 0)
					{
						ctx.local_types.set(vd.name.text, ctx.current_assoc_type);
					}
				}
			}

		case VAR_DECL:
			{
				VarDecl* vd = c.as(VarDecl);
				if (vd.name && vd.type)
				{
					String tname = cursor::spelling(vd.type, tmem);
					if (tname.len > 0) ctx.local_types.set(vd.name.text, tname);
				}
			}

		case CALL_EXPR:
			{
				CallExpr* call = c.as(CallExpr);
				if (!call.callee || call.args.len == 0) break;

				Node* callee_node = resolve_inlay_callee(ctx, call);
				if (!callee_node) break;

				NodeArray params = {};
				switch (callee_node.kind)
				{
					case FN_DECL:
						params = callee_node.as(FnDecl).params;
					case MACRO_DECL:
						params = callee_node.as(MacroDecl).params;
					case VAR_DECL:
						{
							VarDecl* vd = callee_node.as(VarDecl);
							if (vd.type && vd.type.kind == TYPE_EXPR)
							{
								TypeExpr* te = vd.type.as(TypeExpr);
								if (te.type_kind == TYPE_FUNCTION)
								{
									params = te.func.params;
								}
							}
						}
					default:
						break;
				}

				if (params.len == 0) break;

				sz param_offset = 0;
				bool is_method = false;
				if (callee_node.kind == FN_DECL && callee_node.as(FnDecl).associated_type != null)
				{
					is_method = true;
				}
				else if (callee_node.kind == MACRO_DECL && @ok(callee_node.as(MacroDecl).associated_type.get()))
				{
					is_method = true;
				}

				if (call.callee.kind == ACCESS_EXPR && is_method && params.len > 0)
				{
					param_offset = 1;
				}

				for (sz i = 0; i < call.args.len; i++)
				{
					sz param_idx = i + param_offset;
					if (param_idx >= params.len) break;

					Node* arg = call.args[i];
					if (!arg || arg.kind == ERROR) continue;

					if (arg.kind == NAMED_ARG_EXPR || arg.kind == EVAL_NAMED_ARG_EXPR) continue;

					Node* param_node = params[param_idx];
					if (!param_node || param_node.kind != VAR_DECL) continue;
					VarDecl* pdecl = param_node.as(VarDecl);

					String pname = pdecl.name ? pdecl.name.text.strip_prefix("#").strip_prefix("$") : "";
					if (pname.len == 0) continue;

					ctx.hints.push(
					{
						.position = {
							.line = arg.range.start.line >= 0 ? (uint)arg.range.start.line : 0,
							.character = arg.range.start.column >= 0 ? (uint)arg.range.start.column : 0
						},
						.label = string::tformat("%s:", pname),
						.kind = PARAMETER,
						.paddingLeft = false,
						.paddingRight = true
					}
					);
				}
			}
		default:
			break;
	}

	return RECURSE;
}

fn InlayHint[]? get_inlay_hints(LspProject* project, Uri uri, LspRange range)
{
	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf) return {};

	List{InlayHint} hints;
	hints.tinit();

	String caller_mod = query::get_source_file_module_name(sf);

	InlayHintCollector collector = {
		.project = project,
		.sf = sf,
		.caller_mod = caller_mod,
		.range = range,
		.hints = &hints
	};
	collector.local_types.tinit();

	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		if (stmt.range.end.line < (int)range.start.line || stmt.range.start.line > (int)range.end.line) continue;
		cursor::visit(stmt, null, {.on_enter = &collect_inlay_hints_callback }, &collector);
	}

	return hints.array_view();
}
