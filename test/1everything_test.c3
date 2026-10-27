module everything_test @test;

import std::io;
import std::io::file;
import lsp::core;
import lsp;

fn void check_everything()
{
	LspWorkspace ws;
	ws.init(mem);
	defer ws.free();

	String content = (String)file::load(tmem, "test/1everything.c3")!!;
	ws.process_file("test/1everything.c3", content);

	LspDiagnostic[] diags = ws.get_diagnostics("test/1everything.c3");
	io::eprintfn("Total errors: %d", diags.len);
	foreach (d : diags)
	{
		io::eprintfn("[%d:%d] %s", d.range.start.line + 1, d.range.start.character + 1, d.message);
	}

	test::eq(diags.len, 0);
}