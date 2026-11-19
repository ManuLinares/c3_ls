module lsp::analysis::signature_help;
import analyzer, lsp, uri, std::collections::list, std::io;

fn SignatureHelpResult? signature_help(LspProject* project, Uri uri, LspPosition pos)
{
	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf || !project.workspace.ctx) return {.signatures = {} };

	sz offset = utils::compute_byte_offset(sf.content, pos.line, pos.character);

	CallTargetInfo target_info = utils::parse_call_context(sf.content, offset);
	if (!target_info.is_valid) return {.signatures = {} };

	AnalyzerContext* actx = project.workspace.ctx;
	CallTarget target = analysis::call_target_of(actx, sf, target_info);
	if (!target.decl) return {.signatures = {} };

	String symbol_name = target_info.callee_name;
	if (try dot_idx = symbol_name.rindex_of_char('.'))
	{
		symbol_name = symbol_name[dot_idx + 1..];
	}
	if (try sc_idx = symbol_name.rindex_of("::"))
	{
		symbol_name = symbol_name[sc_idx + 2..];
	}

	String sig_label = declaration::signature(actx, target.decl, symbol_name, true);

	List{ParameterInformation} params;
	params.tinit();
	foreach (p : target.params[target.first_param..])
	{
		if (!p || p.kind != VAR_DECL) continue;
		params.push({ .label = declaration::text(actx, p, true) });
	}

	SignatureInformation[] sig_list = alloc::alloc_array(tmem, SignatureInformation, 1);
	sig_list[0] = {
		.label = sig_label,
		.documentation = {
			.kind = MARKDOWN,
			.value = declaration::docs(target.decl)
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