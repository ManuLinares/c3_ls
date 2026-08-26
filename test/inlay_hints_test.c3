module lsp::inlay_hints_test @test;

import lsp::core;
import lsp::analysis::inlay_hints;
import lsp;
import uri;
import std::io;

fn void test_inlay_hints_parameter_names()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

fn void draw_rect(int x, int y, int width, int height, String color) {}

fn void main() {
  draw_rect(10, 20, 100, 50, "red");
}
`;

	proj.workspace.process_file("/virtual/hints.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/hints.c3");
	defer doc_uri.free();

	LspRange full_range = {
		.start = {.line = 0,.character = 0 },
		.end = {.line = 10,.character = 0 }
	};

	InlayHint[] hints = inlay_hints::get_inlay_hints(&proj, doc_uri, full_range)!!;
	assert(hints.len == 5);

	assert(hints[0].label == "x:");
	assert(hints[0].kind == PARAMETER);
	assert(hints[1].label == "y:");
	assert(hints[2].label == "width:");
	assert(hints[3].label == "height:");
	assert(hints[4].label == "color:");
}

fn void test_inlay_hints_skip_named_arguments()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

fn void configure(int port, String host, bool ssl) {}

fn void main() {
  configure(8080, host: "localhost", ssl: true);
}
`;

	proj.workspace.process_file("/virtual/hints_named.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/hints_named.c3");
	defer doc_uri.free();

	LspRange full_range = {
		.start = {.line = 0,.character = 0 },
		.end = {.line = 10,.character = 0 }
	};

	InlayHint[] hints = inlay_hints::get_inlay_hints(&proj, doc_uri, full_range)!!;
	// Only the first argument `8080` was unnamed, so only 1 hint should be emitted
	assert(hints.len == 1);
	assert(hints[0].label == "port:");
}

fn void test_inlay_hints_method_call()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

struct Point { int x; int y; }

fn void Point.move_by(&self, int dx, int dy) {
  self.x += dx;
  self.y += dy;
}

fn void main() {
  Point p;
  p.move_by(5, 10);
}
`;

	proj.workspace.process_file("/virtual/hints_method.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/hints_method.c3");
	defer doc_uri.free();

	LspRange full_range = {
		.start = {.line = 0,.character = 0 },
		.end = {.line = 15,.character = 0 }
	};

	InlayHint[] hints = inlay_hints::get_inlay_hints(&proj, doc_uri, full_range)!!;
	assert(hints.len == 2);
	assert(hints[0].label == "dx:");
	assert(hints[1].label == "dy:");
}
