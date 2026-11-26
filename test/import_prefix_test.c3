module lsp::import_prefix_test;
import lsp;

fn bool reports_missing(String source) @local
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/app.c3", source);
	foreach (diag : proj.workspace.get_diagnostics("/virtual/app.c3"))
	{
		if (diag.message.contains("No module 'nosuch' found")) return true;
	}
	return false;
}

fn void missing_module_after_prefix_import_is_reported() @test
{
	assert(reports_missing("module app;\nimport outer, nosuch;\nfn void main() {}\n\nmodule outer::inner;\nfn void f() {}\n"));
}

fn void missing_module_alone_is_reported() @test
{
	assert(reports_missing("module app;\nimport nosuch;\nfn void main() {}\n"));
}
