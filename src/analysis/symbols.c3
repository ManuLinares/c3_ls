module lsp::analysis::symbols;

import analyzer::core;
import std::collections::list;

import lsp::core;
import lsp;
import lsp::analysis;
import uri;

const sz MAX_WORKSPACE_SYMBOLS = 512;

fn SymbolInformation[]? get_document_symbols(LspProject* project, Uri uri)
{
	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf) return {};

	List{SymbolInformation} symbols;
	symbols.tinit();

	String file_uri = uri.to_raw_string(tmem);
	analysis::collect_file_symbols(sf, file_uri, "", 0, &symbols);

	return symbols.array_view();
}

fn SymbolInformation[]? query_workspace_symbols(LspProject* project, String query)
{
	List{SymbolInformation} results;
	results.tinit();

	if (!project.workspace.ctx) return results.array_view();

	String q_lower = query.to_lower_tcopy();

	project.workspace.ctx.files.@each(; file_path, sf)
	{
		if (results.len() >= MAX_WORKSPACE_SYMBOLS) return results.array_view();

		if (sf && sf.ast.statements.len() > 0)
		{
			Uri u = uri::from_file_path(tmem, file_path);
			String file_uri = u.to_raw_string(tmem);
			analysis::collect_file_symbols(sf, file_uri, q_lower, MAX_WORKSPACE_SYMBOLS, &results);
		}
	};

	return results.array_view();
}
