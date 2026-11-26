module lsp::fault_visibility_test @test;
import lsp::core, lsp::analysis::completion, lsp, uri;

fn void private_fault_in_faultdef_list_hidden()
{
	String src = "module a;\nfaultdef A @private, B;\n\nmodule b;\nimport a;\nfn void f()\n{\n\ta::\n}\n";
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/faults.c3", src);
	Uri doc_uri = uri::from_file_path(tmem, "/virtual/faults.c3");
	bool has_a;
	bool has_b;
	foreach (item : completion::resolve(&proj, doc_uri, { .line = 7, .character = 4 })!!)
	{
		if (item.label == "A") has_a = true;
		if (item.label == "B") has_b = true;
	}
	test::eq(has_a, false);
	test::eq(has_b, true);
}
