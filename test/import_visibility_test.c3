module lsp::import_visibility_test;

import lsp, std::io;

fn LspDiagnostic[] diagnostics_for(LspProject* proj, String src)
{
	String path = "/virtual/imports.c3";
	proj.workspace.process_file(path, src);
	LspDiagnostic[] diags = proj.workspace.get_diagnostics(path);
	LspDiagnostic[] copy = mem::temp_array(LspDiagnostic, diags.len);
	foreach (i, d : diags) copy[i] = { .range = d.range, .severity = d.severity, .message = d.message.copy(tmem) };
	return copy;
}

fn void unimported_stdlib_type_reported() @test
{
	stdlib_fixture::@with_stdlib_project(; LspProject* proj)
	{
		LspDiagnostic[] diags = diagnostics_for(proj, "module t;\nfn void main() { List{int} x; }\n");
		assert(diags.len == 1, "%d diagnostics", diags.len);
		assert(diags[0].range.start.line == 1 && diags[0].range.start.character == 17, "range %s", diags[0].range);
	};
}

fn void module_import_makes_stdlib_type_visible() @test
{
	stdlib_fixture::@with_stdlib_project(; LspProject* proj)
	{
		LspDiagnostic[] diags = diagnostics_for(proj, "module t;\nimport std::collections::list;\nfn void main() { List{int} x; }\n");
		assert(diags.len == 0, "%d diagnostics: %s", diags.len, diags.len ? diags[0].message : "");
	};
}

fn void import_std_makes_stdlib_type_visible() @test
{
	stdlib_fixture::@with_stdlib_project(; LspProject* proj)
	{
		LspDiagnostic[] diags = diagnostics_for(proj, "module t;\nimport std;\nfn void main() { List{int} x; }\n");
		assert(diags.len == 0, "%d diagnostics: %s", diags.len, diags.len ? diags[0].message : "");
	};
}
