module lsp::stdlib_rename_test;

import lsp, uri, std::io, std::io::path, analyzer::core;

const String APP_PATH = "/virtual/app.c3";
const String APP = `module app;
import std::io::path;
fn void main()
{
	(void)path::temp_directory(tmem);
	String s = "x";
}
`;

<* Position of the first `needle` in `src`. *>
fn LspPosition pos_of(String src, String needle)
{
	sz idx = src.index_of(needle)!!;
	uint line = 0;
	sz line_start = 0;
	foreach (i, c : src[:idx])
	{
		if (c == '\n')
		{
			line++;
			line_start = i + 1;
		}
	}
	return { .line = line, .character = (uint)(idx - line_start) };
}

fn void stdlib_symbol_not_renameable_from_workspace_file() @test
{
	stdlib_fixture::@with_stdlib_project(; LspProject* proj)
	{
		proj.workspace.process_file(APP_PATH, APP);
		Uri app = uri::from_file_path(tmem, APP_PATH);

		LspPosition at_string = pos_of(APP, "String");
		assert(@catch(rename::prepare_rename(proj, app, at_string)) == NOT_FOUND);
		assert(@catch(rename::rename(proj, app, at_string, "Text")) == NOT_FOUND);

		LspPosition at_fn = pos_of(APP, "temp_directory");
		assert(@catch(rename::prepare_rename(proj, app, at_fn)) == NOT_FOUND);
	};
}

fn void stdlib_symbol_renameable_from_stdlib_file() @test
{
	stdlib_fixture::@with_stdlib_project(; LspProject* proj)
	{
		proj.workspace.process_file(APP_PATH, APP);

		String std_file = ((String)path::tnew(server::std_path)!!.tappend("std/io/path.c3")!!).treplace("\\", "/");
		SourceFile* sf = proj.workspace.get_source_file_by_path(std_file);
		assert(sf != null, "%s not loaded", std_file);
		Uri std_uri = uri::from_file_path(tmem, std_file);
		LspPosition decl = pos_of(sf.content, "fn Path? temp_directory");
		decl.character += 9;

		LspRange r = rename::prepare_rename(proj, std_uri, decl)!!;
		assert(r.start.line == decl.line && r.end.character - r.start.character == 14);

		WorkspaceEdit e = rename::rename(proj, std_uri, decl, "tmp_dir")!!;
		String app_raw = uri::from_file_path(tmem, APP_PATH).to_raw_string(tmem);
		String std_raw = std_uri.to_raw_string(tmem);
		bool in_app;
		bool in_std;
		foreach (dc : e.documentChanges)
		{
			if (dc.textDocument.uri == app_raw)
			{
				in_app = true;
				assert(dc.edits.len == 1, "%d app edits", dc.edits.len);
			}
			if (dc.textDocument.uri == std_raw) in_std = true;
		}
		assert(in_app && in_std, "app=%s std=%s", in_app, in_std);
	};
}
