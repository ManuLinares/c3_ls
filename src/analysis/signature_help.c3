module lsp::analysis::signature_help;
import analyzer, lsp, uri, std::collections::list, std::io;

fn SignatureHelpResult? signature_help(LspProject* project, Uri uri, LspPosition pos)
{
	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf || !project.workspace.ctx) return {.signatures = {} };

	sz offset = utils::compute_byte_offset(sf.content, pos.line, pos.character);

	CallTargetInfo target_info = utils::parse_call_context(sf.content, offset);
	if (!target_info.is_valid) return {.signatures = {} };

	Location loc = {
		.line = (int)pos.line,
		.column = (int)pos.character
	};
	Node* callee_node = query::resolve_callee_by_name(project.workspace.ctx, sf, target_info.callee_name, loc);
	if (!callee_node) return {.signatures = {} };

	String symbol_name = target_info.callee_name;
	if (try dot_idx = symbol_name.rindex_of_char('.'))
	{
		symbol_name = symbol_name[dot_idx + 1..];
	}
	if (try sc_idx = symbol_name.rindex_of("::"))
	{
		symbol_name = symbol_name[sc_idx + 2..];
	}

	AnalyzerContext* actx = project.workspace.ctx;
	String sig_label = declaration::signature(actx, callee_node, symbol_name, true);

	// `obj.m(...)` passes `obj` as the first parameter; `Type.m(&obj, ...)` does not.
	bool is_method_call = false;
	if (try dot_idx = target_info.callee_name.rindex_of_char('.'))
	{
		String receiver = target_info.callee_name[:dot_idx];
		is_method_call = !query::find_type_node_in_context(actx, sf, receiver, loc);
	}

	Node*[] decl_params;
	bool is_method_decl;
	switch (callee_node.kind)
	{
		case FN_DECL:
			FnDecl* fn_decl = callee_node.as(FnDecl);
			decl_params = fn_decl.params;
			is_method_decl = fn_decl.associated_type != null;
		case MACRO_DECL:
			MacroDecl* mac_decl = callee_node.as(MacroDecl);
			decl_params = mac_decl.params;
			is_method_decl = @ok(mac_decl.associated_type.get());
		default:
			break;
	}

	List{ParameterInformation} params;
	params.tinit();
	foreach (i, p : decl_params)
	{
		if (i == 0 && is_method_call && is_method_decl) continue;
		if (!p || p.kind != VAR_DECL) continue;
		params.push({ .label = declaration::text(actx, p, true) });
	}

	SignatureInformation[] sig_list = alloc::alloc_array(tmem, SignatureInformation, 1);
	sig_list[0] = {
		.label = sig_label,
		.documentation = {
			.kind = MARKDOWN,
			.value = declaration::docs(callee_node)
		},
		.parameters = params.array_view(),
		.activeParameter = target_info.active_param
	};

	return {
		.signatures = sig_list,
		.activeSignature = 0,
		.activeParameter = target_info.active_param
	};
}