module lsp::macro_expand_test @test;

import lsp::core;
import lsp::analysis::hover;
import lsp::analysis::goto_definition;
import lsp::analysis::macro_expand;
import lsp;
import uri;
import std::io;

fn void test_expression_macro_expansion()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
macro int square(x) => x * x;
fn void main() {
  int res = square(5 + 2);
}
`;

	proj.workspace.process_file("/virtual/macro_expr.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/macro_expr.c3");
	defer doc_uri.free();
	// Hover over `square` call on line 3, character 14
	LspPosition pos = {.line = 3,.character = 14 };
	String h = hover::hover(&proj, doc_uri, pos)!!;

	assert(h.contains("macro int square(x)"));
	assert(h.contains("Macro Expansion"));
	assert(h.contains("5 + 2 * 5 + 2"));
}

fn void test_statement_macro_expansion_with_hash_params()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
macro void @swap(#a, #b) {
  var temp = #a;
  #a = #b;
  #b = temp;
}
fn void main() {
  int x = 1;
  int y = 2;
  @swap(x, y);
}
`;

	proj.workspace.process_file("/virtual/macro_swap.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/macro_swap.c3");
	defer doc_uri.free();
	// Hover over `@swap` call on line 9, character 4
	LspPosition pos = {.line = 9,.character = 4 };
	String h = hover::hover(&proj, doc_uri, pos)!!;

	assert(h.contains("macro @swap(#a, #b)"));
	assert(h.contains("Macro Expansion"));
	assert(h.contains("var temp = x;"));
	assert(h.contains("x = y;"));
	assert(h.contains("y = temp;"));
}

fn void test_min_variadic_macro_signature_and_hover()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
macro min(x, ...) @builtin {
  $if $vaarg.len == 1:
    return x;
  $else
    return x;
  $endif
}
fn void main() {
  int res = min(10, 20);
}
`;

	proj.workspace.process_file("/virtual/min_macro.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/min_macro.c3");
	defer doc_uri.free();

	LspPosition pos = {.line = 9,.character = 14 };
	String h = hover::hover(&proj, doc_uri, pos)!!;

	assert(h.contains("macro min(x, ...)"));
}

fn void test_unlikely_macro_signature_with_default_args()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
macro bool @unlikely(bool #value, $probability = 1.0) @builtin {
  $switch:
    $case $probability == 1.0:
      return #value;
    $default:
      return #value;
  $endswitch
}
fn void run() {
  if (@unlikely(1 < 2)) {}
}
`;

	proj.workspace.process_file("/virtual/unlikely_macro.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/unlikely_macro.c3");
	defer doc_uri.free();

	LspPosition pos = {.line = 10,.character = 9 };
	String h = hover::hover(&proj, doc_uri, pos)!!;

	assert(h.contains("macro bool @unlikely(bool #value, $probability = 1.0)"));
}

fn void test_result_module_generics_and_or_else_macro()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module std::collections::result <OkType, ErrType>;

struct Result {
  OkType ok_val;
  ErrType err_val;
}

<*
 Return the value or execute the expression.
 @require $defined(Result res = self)
*>
macro OkType Result.@or_else(&self; @body(Result res)) {
  return self.ok_val;
}

fn void test_res() {
  Result r;
  r.or_else();
}
`;

	proj.workspace.process_file("/virtual/result_test.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/result_test.c3");
	defer doc_uri.free();
	// 1. Go to definition on `OkType` in `struct Result` (line 3, col 4)
	LspPosition ok_type_pos = {.line = 3,.character = 4 };
	LspLocation[] ok_locs = goto_definition::goto_definition(&proj, doc_uri, ok_type_pos)!!;
	assert(ok_locs.len > 0);
	assert(ok_locs[0].range.start.line == 0);
	// 2. Hover on `OkType` in `struct Result`
	String ok_hover = hover::hover(&proj, doc_uri, ok_type_pos)!!;
	assert(ok_hover.contains("type OkType"));
	// 3. Hover on `or_else` method call (line 17, col 6)
	LspPosition or_else_pos = {.line = 17,.character = 6 };
	String or_else_hover = hover::hover(&proj, doc_uri, or_else_pos)!!;
	assert(or_else_hover.contains("macro OkType Result.@or_else"));
	assert(or_else_hover.contains("@body"));
	// 4. Go to definition on `or_else`
	LspLocation[] or_else_locs = goto_definition::goto_definition(&proj, doc_uri, or_else_pos)!!;
	assert(or_else_locs.len > 0);
	assert(or_else_locs[0].range.start.line == 11);
}

fn void test_compile_time_stringify_evaluation()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
fn void log_expr() {
  String s = $stringify(foo.bar + 10);
}
`;

	proj.workspace.process_file("/virtual/ct_stringify.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/ct_stringify.c3");
	defer doc_uri.free();
	// Hover over `$stringify(foo.bar + 10)` on line 2, character 16
	LspPosition pos = {.line = 2,.character = 16 };
	String h = hover::hover(&proj, doc_uri, pos)!!;

	assert(h.contains("Compile-Time Evaluation"));
	assert(h.contains("\"foo.bar + 10\""));
}

fn void test_compile_time_typeof_evaluation()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
struct Point { int x; int y; }
fn void check_type() {
  Point pt;
  $Typeof(pt) copy;
}
`;

	proj.workspace.process_file("/virtual/ct_typeof.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/ct_typeof.c3");
	defer doc_uri.free();
	// Hover over `$Typeof(pt)` on line 4, character 4
	LspPosition pos = {.line = 4,.character = 4 };
	String h = hover::hover(&proj, doc_uri, pos)!!;

	assert(h.contains("Compile-Time Evaluation"));
	assert(h.contains("typeid (Point)"));
}

fn void test_compile_time_reflection_properties()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
enum Status : int { IDLE, RUNNING, FINISHED }
fn void main() {
  sz int_sz = int::size;
  sz align_sz = double::alignment;
  sz status_len = Status::len;
}
`;

	proj.workspace.process_file("/virtual/reflection_eval.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/reflection_eval.c3");
	defer doc_uri.free();
	// 1. Hover on `int::size` (line 3, col 18)
	LspPosition int_sz_pos = {.line = 3,.character = 18 };
	String h1 = hover::hover(&proj, doc_uri, int_sz_pos)!!;
	assert(h1.contains("4 (bytes)"));
	// 2. Hover on `double::alignment` (line 4, col 20)
	LspPosition dbl_align_pos = {.line = 4,.character = 20 };
	String h2 = hover::hover(&proj, doc_uri, dbl_align_pos)!!;
	assert(h2.contains("8 (bytes)"));
	// 3. Hover on `Status::len` (line 5, col 23)
	LspPosition status_len_pos = {.line = 5,.character = 23 };
	String h3 = hover::hover(&proj, doc_uri, status_len_pos)!!;
	assert(h3.contains("3 (variants)"));
}
