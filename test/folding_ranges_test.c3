// test/folding_ranges_test.c3
module lsp::folding_ranges_test @test;

import lsp::core;
import lsp::analysis::folding_ranges;
import lsp;
import uri;
import std::io;

fn void test_folding_ranges_blocks_and_imports()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

import std::io;
import std::math;
import std::time;

struct Config {
  int port;
  String host;
}

fn void run() {
  int x = 1;
  int y = 2;
}
`;

	proj.workspace.process_file("/virtual/folding.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/folding.c3");
	defer doc_uri.free();

	FoldingRange[] ranges = folding_ranges::get_folding_ranges(&proj, doc_uri)!!;
	assert(ranges.len >= 3);

	bool found_imports = false;
	bool found_struct = false;
	bool found_function = false;

	foreach (r : ranges)
	{
		if (r.kind == "imports" && r.startLine == 2 && r.endLine == 4) found_imports = true;
		if (r.kind == "region" && r.startLine == 6 && r.endLine == 9) found_struct = true;
		if (r.kind == "region" && r.startLine == 11 && r.endLine == 14) found_function = true;
	}

	assert(found_imports);
	assert(found_struct);
	assert(found_function);
}

fn void test_folding_ranges_comments()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

/*
 Multi-line comment
 that spans across
 four lines
*/

<*
 Doc contract description
 spanning multiple lines
*>
fn void test_fn() {}
`;

	proj.workspace.process_file("/virtual/folding_comments.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/folding_comments.c3");
	defer doc_uri.free();

	FoldingRange[] ranges = folding_ranges::get_folding_ranges(&proj, doc_uri)!!;
	assert(ranges.len >= 2);

	bool found_comment = false;
	foreach (r : ranges)
	{
		if (r.kind == "comment" && r.startLine == 2 && r.endLine == 6) found_comment = true;
	}

	assert(found_comment);
}