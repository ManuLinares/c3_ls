module lsp::formatting_glitches_test;

import lsp::core;
import lsp::analysis::formatting;
import lsp;
import uri;
import std::io;
<*
 Helper function to format a string and return the formatted output.
 Defined in a non-@test module section because it takes parameters.
*>
fn String format_code(String code, uint tab_size = 4, bool insert_spaces = false)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	Uri doc_uri = uri::from_file_path(mem, "/virtual/test.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/test.c3", code);

	FormattingOptions options = {
		.tab_size = tab_size,
		.insert_spaces = insert_spaces,
		.insert_final_newline = true,
		.trim_trailing_whitespace = true,
		.trim_final_newlines = true
	};

	TextEdit[] edits = formatting::format_document(&proj, doc_uri, options)!!;
	if (edits.len == 0) return code;
	return edits[0].newText;
}

module lsp::formatting_glitches_test @test;

import lsp::core;
import lsp::analysis::formatting;
import lsp;
import uri;
import std::io;

fn void test_declaration_generic_brackets_tight()
{
	String code = `module app;
typedef PriorityQueue <Type> = inline PrivatePriorityQueue{Type, false};
typedef PriorityQueueMax <Type> = inline PrivatePriorityQueue{Type, true};
struct Map <Key, Value> {
	Key k;
	Value v;
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("typedef PriorityQueue <Type> = inline PrivatePriorityQueue{Type, false};"));
	assert(!formatted.contains("< Type>"));
	assert(!formatted.contains("< Type >"));
	assert(formatted.contains("typedef PriorityQueueMax <Type> = inline PrivatePriorityQueue{Type, true};"));
	assert(formatted.contains("struct Map <Key, Value>"));
}

fn void test_operator_overload_brackets_tight()
{
	String code = `module app;
struct Foo {}
fn bool Foo.set(&self, Key key, Value value) @operator([]=) => false;
fn Value Foo.get(&self, Key key) @operator([]) => {};
fn sz Foo.len(&self) @operator(len) => 0;
`;
	String formatted = format_code(code);
	assert(formatted.contains("@operator([]=)"));
	assert(!formatted.contains("([]= )"));
	assert(formatted.contains("@operator([])"));
	assert(!formatted.contains("([] )"));
}

fn void test_boolean_and_bitwise_operators_spacing()
{
	String code = `module app;
fn void test(bool WANT_ROUNDING, double y, Node* lit, uint flags, uint first_tag) {
	if (WANT_ROUNDING && y == 0.0) y = 0.0;
	if (is_tag(lit) && (flags & COPY_MAXIMIZE_FIRST_TAG) != 0 && first_tag != 0) {
		return;
	}
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("if (WANT_ROUNDING && y == 0.0) y = 0.0;"));
	assert(!formatted.contains("WANT_ROUNDING&&y"));
	assert(formatted.contains("is_tag(lit) && (flags & COPY_MAXIMIZE_FIRST_TAG) != 0 && first_tag != 0"));
	assert(!formatted.contains("&COPY_MAXIMIZE"));
	assert(!formatted.contains("lit)&&"));
}

fn void test_unary_dereference_at_statement_start()
{
	String code = `module app;
fn void test(Node* result, Allocator allocator, sz min, sz max, Range pos) {
	*result = ast_new_literal(allocator, min, max, pos)!;
	*ptr = 10;
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("*result = ast_new_literal"));
	assert(!formatted.contains("* result ="));
	assert(formatted.contains("*ptr = 10;"));
	assert(!formatted.contains("* ptr ="));
}

fn void test_optional_return_types_no_stray_space()
{
	String code = `module app;
fn char[]? decompress(Allocator allocator, char[] input) => @pool();
fn Type*? get_ptr() => null;
fn List{int}? get_list() => null;
fn int[<2>]? get_vec() => null;
fn void test() {
	char[]? buffer;
	int*? ptr;
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("fn char[]? decompress"));
	assert(!formatted.contains("char[] ?"));
	assert(formatted.contains("fn Type*? get_ptr"));
	assert(!formatted.contains("Type* ?"));
	assert(formatted.contains("fn List{int}? get_list"));
	assert(!formatted.contains("List{int} ?"));
	assert(formatted.contains("fn int[<2>]? get_vec"));
	assert(!formatted.contains("int[<2>] ?"));
	assert(formatted.contains("char[]? buffer;"));
	assert(formatted.contains("int*? ptr;"));
}

fn void test_space_after_keywords_before_unary_and_ct_macros()
{
	String code = `module app;
fn void test(bool fill_with, Node* u) {
	$if $defined(#init):
		int x = 1;
	$endif

	switch (u) {
		case !u.parent:
			break;
		default:
			break;
	}

	if !$defined(fill_with):
		return;
	$endif

	if (!u) return;
	if !u.parent return;
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("$if $defined(#init):"));
	assert(!formatted.contains("$if$defined"));
	assert(formatted.contains("case !u.parent:"));
	assert(!formatted.contains("case!u.parent"));
	assert(formatted.contains("if !$defined(fill_with):"));
	assert(!formatted.contains("if!$defined"));
}

fn void test_unary_deref_and_addrof_spacing()
{
	String code = `module app;
const Allocator SET_HEAP_ALLOCATOR = (Allocator)&dummy;
fn void run() {
	*(Header*)output.ptr = { 1, 2 };
	int* p = &dummy;
	foreach (&ref : *val) {
		*ref = 1;
	}
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("(Allocator)&dummy"));
	assert(!formatted.contains("& dummy"));
	assert(formatted.contains("*(Header*)output.ptr"));
	assert(!formatted.contains("* (Header*)"));
	assert(formatted.contains("foreach (&ref : *val)"));
	assert(!formatted.contains(":*val"));
}

fn void test_ct_foreach_header_stays_on_one_line()
{
	String code = `module app;
macro void run() {
	$foreach $member : ResultType::members:
		recursively_free{$member.type}(allocator, &val.$member);
	$endforeach

	$foreach $i, $member : ResultType::members:
		process($i, $member);
	$endforeach
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("$foreach $member : ResultType::members:\n"));
	assert(formatted.contains("$foreach $i, $member : ResultType::members:\n"));
	assert(!formatted.contains("$foreach $member:\n"));
}

fn void test_labeled_control_statements_space_before_paren()
{
	String code = `module app;
fn void loop() {
	while OUTER: (2 * i + 1 < new_count) {
		if (i > 10) break OUTER;
	}
	do SET_DONE: {
		break SET_DONE;
	};
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("while OUTER: (2 * i + 1 < new_count)"));
	assert(!formatted.contains("while OUTER:("));
	assert(formatted.contains("do SET_DONE:"));
}

fn void test_empty_compound_literals_and_initializers_inline()
{
	String code = `module app;
fn void main() {
	if (!self.size) return ($Type[]){};
	if (!self.size) return {};
	int[] arr = {};
	Point p = {};
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("return ($Type[]){};"));
	assert(formatted.contains("return {};"));
	assert(formatted.contains("int[] arr = {};"));
	assert(formatted.contains("Point p = {};"));
}

fn void test_bitwise_not_and_assignment_spacing()
{
	String code = `module app;
fn void test() {
	self.data[q] &= ~(1u << r);
	page.ident = ~(sz)0;
	int x = ~y;
	x |= ~(1 << 2);
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("self.data[q] &= ~(1u << r);"));
	assert(!formatted.contains("&=~"));
	assert(formatted.contains("page.ident = ~(sz)0;"));
	assert(!formatted.contains("=~"));
	assert(formatted.contains("x |= ~(1 << 2);"));
	assert(!formatted.contains("|=~"));
}

fn void test_fault_and_rethrow_suffix_tight()
{
	String code = `module app;
faultdef NOT_FOUND, IO_ERROR;
fn int? test() {
	int? x = NOT_FOUND~;
	int y = test() ?? IO_ERROR~!;
	return x;
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("NOT_FOUND~;"));
	assert(!formatted.contains("NOT_FOUND ~"));
	assert(formatted.contains("IO_ERROR~!;"));
	assert(!formatted.contains("IO_ERROR ~ !"));
}

fn void test_block_comments_preserve_newlines_and_spacing()
{
	String code = `/* origin: FreeBSD /usr/src/lib/msun/src/e_atan2f.c */
/*
 * Conversion to float
 */
/*
 * Header copyright
 */

const float PI_F @private = 3.1415927410e+00; /* 0x40490fdb */

fn float _atan2f(float y, float x) {
	uint m = ((iy >> 31) & 1) | ((ix >> 30) & 2);
	if (ix == 0) return m & 1 ? -(float)math::HALF_PI : (float)math::HALF_PI;
	switch (m) {
		case 0: return z;
		default: return (z - PI_LO_F) - PI_F;
	}
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("/* origin: FreeBSD /usr/src/lib/msun/src/e_atan2f.c */\n/*\n * Conversion to float\n */"));
	assert(formatted.contains("*/\n\nconst float PI_F"));
	assert(formatted.contains("((iy >> 31) & 1) | ((ix >> 30) & 2);"));
	assert(formatted.contains("return m & 1 ? -(float)math::HALF_PI : (float)math::HALF_PI;"));
	assert(formatted.contains("default: return (z - PI_LO_F) - PI_F;"));
}

fn void test_comment_newline_preservation() @test
{
	String code = `module app;
fn int main(String[] args)
{
	{}

	// comment
	{};

	// comment
	return 0;
}

// comment
`;

	String formatted = format_code(code);
	assert(formatted.contains("{}\n\n\t// comment\n\t{};"));
	assert(formatted.contains("{};\n\n\t// comment\n\treturn 0;"));
	assert(formatted.contains("}\n\n// comment"));
}

fn void test_ternary_with_const_ident_spacing() @test
{
	String code = `module app;
fn float choose(uint m, float z) {
	return m & 1 ? -(float)math::HALF_PI : (float)math::HALF_PI;
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("return m & 1 ? -(float)math::HALF_PI : (float)math::HALF_PI;"));
	assert(!formatted.contains("HALF_PI:"));
}

fn void test_named_args_and_labels_no_space_before_colon() @test
{
	String code = `module app;
fn void run() {
	init(tmem, capacity: 16, load_factor: 0.75f);
	mem::load(bytes, $align: 1);
	while OUTER: (true) {
		break OUTER;
	}
	do DONE: {
		break DONE;
	};
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("capacity: 16, load_factor: 0.75f"));
	assert(!formatted.contains("capacity :"));
	assert(!formatted.contains("load_factor :"));
	assert(formatted.contains("$align: 1"));
	assert(!formatted.contains("$align :"));
	assert(formatted.contains("while OUTER: (true)"));
	assert(!formatted.contains("while OUTER :"));
	assert(formatted.contains("do DONE:"));
	assert(!formatted.contains("do DONE :"));
}

fn void test_inline_brace_comment_spacing() @test
{
	String code = `module app;
fn void test() {
	{}

	// comment after blank line
	{};

	// another comment
	return;
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("{}\n\n\t// comment after blank line\n\t{};"));
	assert(formatted.contains("{};\n\n\t// another comment\n\treturn;"));
	assert(!formatted.contains("{}  //"));
}

fn void test_bitstruct_field_colons_tight() @test
{
	String code = `module app;
bitstruct Flags : char {
	bool text: 0;
	bool hcrc: 1;
	uint reserved: 5..7;
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("bool text: 0;"));
	assert(!formatted.contains("text :"));
	assert(formatted.contains("bool hcrc: 1;"));
	assert(formatted.contains("uint reserved: 5..7;"));
	assert(!formatted.contains("reserved :"));
}

fn void test_named_arguments_colons_tight() @test
{
	String code = `module app;
fn void test() {
	allocator.release(ptr, aligned: true);
	return self.init_with_values(tmem, ...$vaarg, capacity: capacity, load_factor: load_factor);
	mem::load(bytes, $align: 1);
}
`;
	String formatted = format_code(code);
	assert(formatted.contains("aligned: true"));
	assert(!formatted.contains("aligned :"));
	assert(formatted.contains("capacity: capacity, load_factor: load_factor"));
	assert(!formatted.contains("capacity :"));
	assert(!formatted.contains("load_factor :"));
	assert(formatted.contains("$align: 1"));
	assert(!formatted.contains("$align :"));
}

fn void test_state_leak_does_not_corrupt_subsequent_colons() @test
{
	String code = `module app;

fn void? check(int? x) {
	int? a = x;
	if (a?) return null;
	return null;
}

struct Empty {}

bitstruct Flags : char {
	bool text: 0;
	bool hcrc: 1;
}

fn void test_calls() {
	allocator.release(ptr, aligned: true);
	init(tmem, capacity: 16, load_factor: 0.75f);
	mem::load(bytes, $align: 1);
	while OUTER: (true) {
		break OUTER;
	}
}
`;

	String formatted = format_code(code);
	assert(formatted.contains("bool text: 0;"));
	assert(!formatted.contains("text :"));
	assert(formatted.contains("aligned: true"));
	assert(!formatted.contains("aligned :"));
	assert(formatted.contains("capacity: 16, load_factor: 0.75f"));
	assert(!formatted.contains("capacity :"));
	assert(formatted.contains("$align: 1"));
	assert(!formatted.contains("$align :"));
	assert(formatted.contains("while OUTER: (true)"));
	assert(!formatted.contains("while OUTER :"));
}

fn void test_ternary_containing_slice_does_not_corrupt_subsequent_colons() @test
{
	String code = `module app;

fn void test_slice_in_ternary(bool flag, char[] buf) {
	char[] res = flag ? buf[:8192] : buf[8192:];
}

bitstruct OpIndex : char {
	char tag: 6..7;
	char index: 0..5;
}

fn void test_named(int x) {
	call(capacity: 16, load_factor: 0.75f);
}
`;

	String formatted = format_code(code);
	assert(formatted.contains("flag ? buf[:8192] : buf[8192:]"));
	assert(formatted.contains("char tag: 6..7;"));
	assert(!formatted.contains("tag :"));
	assert(formatted.contains("char index: 0..5;"));
	assert(!formatted.contains("index :"));
	assert(formatted.contains("capacity: 16, load_factor: 0.75f"));
	assert(!formatted.contains("capacity :"));
}