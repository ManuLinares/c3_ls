module lsp::analysis::hover;
import analyzer, lsp, uri;

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
		if (ct_node.kind == ACCESS_EXPR)
		{
			AccessExpr* acc = ct_node.as(AccessExpr);
			String mem_name = cursor::spelling(acc.member, tmem);
			if (acc.access_kind == STATIC)
			{
				if (try tp = constants::TypeProperty::lookup_field(name, mem_name))
				{
					String left_name = cursor::spelling(acc.left, tmem);
					String ct_eval = macro_expand::evaluate_compile_time(project.workspace.ctx, sf, ct_node);
					DString h_buf;
					h_buf.tinit();
					h_buf.appendf("```c3\n%s::%s : %s\n", left_name, tp.name, tp.type_desc);
					if (ct_eval.len > 0)
					{
						h_buf.appendf("// Compile-Time Evaluation:\n%s\n", ct_eval);
					}
					h_buf.append("```");
					if (tp.doc.len > 0)
					{
						h_buf.appendf("\n\n%s", tp.doc);
					}
					return h_buf.str_view();
				}
			}
			else
			{
				if (acc.member && acc.member.range.contains(loc))
				{
					String recv_type = query::type_of(project.workspace.ctx, sf, acc.left, loc);
					String clean_type = recv_type.trim_right("*&? \t");

					if (mem_name == "len" && (clean_type == "String" || clean_type.ends_with("[]") || clean_type.contains("[")))
					{
						return "```c3\nsz len\n```\n\nNumber of elements in the array, slice, vector, or string.";
					}

					if (mem_name == "ptr" && (clean_type == "String" || clean_type.ends_with("[]")))
					{
						String ptr_type = clean_type == "String" ? "char*" : string::tformat("%s*", clean_type.strip_suffix("[]"));
						return string::tformat("```c3\n%s ptr\n```\n\nPointer to the underlying elements of the array, slice, or string.", ptr_type);
					}
				}

				String left_str = cursor::spelling(acc.left, tmem);
				bool is_reflect = (acc.left && (acc.left.kind == CT_REFLECT_EXPR || left_str.starts_with("$reflect")));
				if (is_reflect)
				{
					if (try rp = constants::ReflectProperty::lookup_field(name, mem_name))
					{
						String ct_eval = macro_expand::evaluate_compile_time(project.workspace.ctx, sf, ct_node);
						DString h_buf;
						h_buf.tinit();
						h_buf.appendf("```c3\n%s.%s : %s\n", left_str, rp.name, rp.type_desc);
						if (ct_eval.len > 0)
						{
							h_buf.appendf("// Compile-Time Evaluation:\n%s\n", ct_eval);
						}
						h_buf.append("```");
						if (rp.doc.len > 0)
						{
							h_buf.appendf("\n\n%s", rp.doc);
						}
						return h_buf.str_view();
					}
				}
			}
		}

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

	if (decl_node.kind == TYPE_EXPR)
	{
		if (try pt = constants::PrimitiveType::lookup_field(name, cursor::raw_type_identifier(decl_node) ?? ""))
		{
			return string::tformat("```c3\n%s\n```\n\n%s", pt.name, pt.doc);
		}
	}

	String symbol_name = analysis::get_node_symbol_name(decl_node);
	if (symbol_name.len == 0 && decl_node.kind != MODULE_DECL && decl_node.kind != PATH_EXPR) return "";

	String doc_comment = declaration::docs(decl_node);
	if (doc_comment.len == 0 && decl_node.kind == ATTRIBUTE_DECL)
	{
		doc_comment = decl_node.as(AttributeDecl).attribute_kind.doc;
	}

	DString md_buf;
	md_buf.tinit();
	md_buf.append(declaration::header(project.workspace.ctx, decl_node, symbol_name));
	if (doc_comment.len > 0) md_buf.appendf("\n\n%s", doc_comment);

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

	return md_buf.str_view();
}
