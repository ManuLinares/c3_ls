module lsp::import_visibility_test;

import lsp, std::io;

fn LspDiagnostic[] diagnostics_for(String src)
{
	if (server::std_path.len == 0) server::setup_stdlib_path();
	defer
	{
		if (server::is_std_path_alloc)
		{
			server::std_path.free(mem);
			server::is_std_path_alloc = false;
			server::std_path = "";
		}
	};
	assert(server::std_path.len > 0, "stdlib path not found");

	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.process_stdlib();
	proj.update();

	String path = "/virtual/imports.c3";
	proj.workspace.process_file(path, src);
	LspDiagnostic[] diags = proj.workspace.get_diagnostics(path);
	LspDiagnostic[] copy = mem::temp_array(LspDiagnostic, diags.len);
	foreach (i, d : diags) copy[i] = { .range = d.range, .severity = d.severity, .message = d.message.copy(tmem) };
	return copy;
}

fn void unimported_stdlib_type_reported() @test
{
	LspDiagnostic[] diags = diagnostics_for("module t;\nfn void main() { List{int} x; }\n");
	assert(diags.len == 1, "%d diagnostics", diags.len);
	assert(diags[0].range.start.line == 1 && diags[0].range.start.character == 17, "range %s", diags[0].range);
}

fn void module_import_makes_stdlib_type_visible() @test
{
	LspDiagnostic[] diags = diagnostics_for("module t;\nimport std::collections::list;\nfn void main() { List{int} x; }\n");
	assert(diags.len == 0, "%d diagnostics: %s", diags.len, diags.len ? diags[0].message : "");
}

fn void import_std_makes_stdlib_type_visible() @test
{
	LspDiagnostic[] diags = diagnostics_for("module t;\nimport std;\nfn void main() { List{int} x; }\n");
	assert(diags.len == 0, "%d diagnostics: %s", diags.len, diags.len ? diags[0].message : "");
}
