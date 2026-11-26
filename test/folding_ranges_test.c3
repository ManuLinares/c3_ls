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
	bool found_docs = false;
	foreach (r : ranges)
	{
		if (r.kind == "comment" && r.startLine == 2 && r.endLine == 6) found_comment = true;
		if (r.kind == "comment" && r.startLine == 8 && r.endLine == 11) found_docs = true;
		assert(r.kind != "comment" || r.startLine == 2 || r.startLine == 8, "extra comment fold %d-%d", r.startLine, r.endLine);
	}

	assert(found_comment);
	assert(found_docs);
}

fn void comment_markers_in_line_comments_and_strings_not_folded()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module app;\n// see /* here\nString s = \"/* not a comment\";\nfn void run()\n{\n\tint x = 1;\n}\n";
	proj.workspace.process_file("/virtual/folding_markers.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/folding_markers.c3");
	defer doc_uri.free();

	foreach (r : folding_ranges::get_folding_ranges(&proj, doc_uri)!!)
	{
		assert(r.kind != "comment", "comment fold %d-%d", r.startLine, r.endLine);
	}
}
