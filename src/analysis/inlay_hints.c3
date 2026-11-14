module lsp::analysis::inlay_hints;
import analyzer, lsp, uri, std::collections::list, std::io;

struct InlayHintCollector
{
	LspProject* project;
	SourceFile* sf;
	LspRange range;
	List{InlayHint} * hints;
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

		case CALL_EXPR:
			{
				CallExpr* call = c.as(CallExpr);
				if (!call.callee || call.args.len == 0) break;

				if (!ctx.project.workspace.ctx) break;
				CallTarget target = query::call_target(ctx.project.workspace.ctx, ctx.sf, call);
				NodeArray params = target.params;
				if (params.len == 0) break;

				for (sz i = 0; i < call.args.len; i++)
				{
					sz param_idx = i + target.first_param;
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

	InlayHintCollector collector = {
		.project = project,
		.sf = sf,
		.range = range,
		.hints = &hints
	};

	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		if (stmt.range.end.line < (int)range.start.line || stmt.range.start.line > (int)range.end.line) continue;
		cursor::visit(stmt, null, {.on_enter = &collect_inlay_hints_callback }, &collector);
	}

	return hints.array_view();
}
