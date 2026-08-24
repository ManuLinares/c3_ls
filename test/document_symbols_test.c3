// test/document_symbols_test.c3
module lsp::document_symbols_test @test;

import lsp::core;
import lsp::analysis::document_symbols;
import lsp;
import uri;
import std::io;

fn void test_document_symbols_outline()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

struct Point {
  int x;
  int y;
}

enum State : int {
  IDLE,
  RUNNING
}

fn void Point.reset(&self) {
  self.x = 0;
  self.y = 0;
}

const int MAX_COUNT = 100;
`;

	proj.workspace.process_file("/virtual/doc_syms.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/doc_syms.c3");
	defer doc_uri.free();

	SymbolInformation[] syms = document_symbols::get_document_symbols(&proj, doc_uri)!!;
	assert(syms.len >= 7);

	bool found_module = false;
	bool found_struct = false;
	bool found_field_x = false;
	bool found_field_y = false;
	bool found_enum = false;
	bool found_enum_idle = false;
	bool found_method = false;
	bool found_const = false;

	foreach (s : syms)
	{
		if (s.name == "app" && s.kind == MODULE) found_module = true;
		if (s.name == "Point" && s.kind == STRUCT) found_struct = true;
		if (s.name == "x" && s.kind == FIELD && s.containerName == "Point") found_field_x = true;
		if (s.name == "y" && s.kind == FIELD && s.containerName == "Point") found_field_y = true;
		if (s.name == "State" && s.kind == ENUM) found_enum = true;
		if (s.name == "IDLE" && s.kind == ENUMMEMBER && s.containerName == "State") found_enum_idle = true;
		if (s.name == "reset" && s.kind == METHOD && s.containerName == "Point") found_method = true;
		if (s.name == "MAX_COUNT" && s.kind == CONSTANT) found_const = true;
	}

	assert(found_module);
	assert(found_struct);
	assert(found_field_x);
	assert(found_field_y);
	assert(found_enum);
	assert(found_enum_idle);
	assert(found_method);
	assert(found_const);
}