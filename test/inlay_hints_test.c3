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

fn void test_inlay_hints_ternary_argument_position() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

fn void test_fn(int foo, int bar) {}

fn void main() {
  bool check = false;
  test_fn(
    0,
    check ? 1 : 0
  );
}
`;

	proj.workspace.process_file("/virtual/hints_ternary.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/hints_ternary.c3");
	defer doc_uri.free();

	LspRange full_range = {
		.start = { .line = 0, .character = 0 },
		.end = { .line = 12, .character = 0 }
	};

	InlayHint[] hints = inlay_hints::get_inlay_hints(&proj, doc_uri, full_range)!!;
	assert(hints.len == 2);

	assert(hints[0].label == "foo:");
	assert(hints[0].position.line == 7);
	assert(hints[0].position.character == 4);

	assert(hints[1].label == "bar:");
	assert(hints[1].position.line == 8);
	assert(hints[1].position.character == 4);
}
fn void test_inlay_hints_before_prefix_operators()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
fn void take(int a, bool b, int c, int* d, int e, int f) {}
fn void main()
{
	int v = 1;
	int* p = &v;
	float f = 2.0;
	take(-5, !true, ~v, &v, *p, (int)f);
}
`;
	proj.workspace.process_file("/virtual/prefix_hints.c3", source);
	Uri doc_uri = uri::from_file_path(tmem, "/virtual/prefix_hints.c3");
	InlayHint[] hints = inlay_hints::get_inlay_hints(&proj, doc_uri, { .start = { 0, 0 }, .end = { 20, 0 } })!!;

	String call_line = source.tsplit("\n")[7];
	String[6] args = { "-5", "!true", "~v", "&v", "*p", "(int)f" };
	String[6] labels = { "a:", "b:", "c:", "d:", "e:", "f:" };
	sz found = 0;
	foreach (hint : hints)
	{
		if (hint.kind != PARAMETER || hint.position.line != 7) continue;
		assert(found < 6, "extra hint %s", hint.label);
		assert(hint.label == labels[found], "%s != %s", hint.label, labels[found]);
		uint want = (uint)call_line.index_of(args[found])!!;
		assert(hint.position.character == want, "%s at %d, %s starts at %d", hint.label, hint.position.character, args[found], want);
		found++;
	}
	assert(found == 6, "%d hints", found);
}

fn void test_inlay_hints_method_receiver()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
struct Canvas { int id; }
fn void Canvas.blit(&self, int x, int y) {}
fn void main()
{
	Canvas c;
	c.blit(1, 2);
	Canvas.blit(&c, 3, 4);
}
`;
	proj.workspace.process_file("/virtual/receiver_hints.c3", source);
	Uri doc_uri = uri::from_file_path(tmem, "/virtual/receiver_hints.c3");
	InlayHint[] hints = inlay_hints::get_inlay_hints(&proj, doc_uri, { .start = { 0, 0 }, .end = { 20, 0 } })!!;

	DString instance = dstring::temp();
	DString through_type = dstring::temp();
	foreach (hint : hints)
	{
		if (hint.kind != PARAMETER) continue;
		if (hint.position.line == 6) instance.append(hint.label);
		if (hint.position.line == 7) through_type.append(hint.label);
	}
	assert(instance.str_view() == "x:y:", "%s", instance);
	assert(through_type.str_view() == "self:x:y:", "%s", through_type);
}

fn void test_inlay_hints_function_pointer_call()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
alias Callback = fn void(int count);
fn void tick(int count) {}
fn void main()
{
	Callback cb = &tick;
	cb(3);
}
`;
	proj.workspace.process_file("/virtual/fn_ptr_hint.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/fn_ptr_hint.c3");
	defer doc_uri.free();

	InlayHint[] hints = inlay_hints::get_inlay_hints(&proj, doc_uri, { .end = { .line = 8 } })!!;
	assert(hints.len == 1);
	assert(hints[0].label == "count:");
	assert(hints[0].position.line == 6 && hints[0].position.character == 4);
}
