module experimental_synonyms_test @test;

import analyzer::core;
import analyzer::parser;
import lsp::core;
import lsp::analysis::hover;
import lsp::analysis::goto_definition;
import lsp::analysis::document_symbols;
import lsp;
import uri;
import std::io;

fn void test_distinct_keyword_as_typedef()
{
	String source = `module app;
distinct MyId = int;
distinct Handle @constinit = inline int;
fn void use_handle(Handle h) {
  MyId id = (MyId)10;
}
`;

	AnalyzerContext* ctx = context::create(tmem);
	bool success = context::process(ctx, source, "test_distinct.c3");
	assert(success);

	Module* mod = ctx.modules.get("app")!!;
	test::eq(mod.nodes.len(), 4);

	Node* td_node = mod.nodes[1];
	test::eq(td_node.kind, NodeKind.TYPEDEF_DECL);
	TypedefDecl* td = td_node.as(TypedefDecl);
	test::eq(td.name.text, "MyId");

	Node* handle_node = mod.nodes[2];
	test::eq(handle_node.kind, NodeKind.TYPEDEF_DECL);
	TypedefDecl* htd = handle_node.as(TypedefDecl);
	test::eq(htd.name.text, "Handle");
	test::eq(htd.is_inline, true);
}

fn void test_constset_and_cenum_keywords()
{
	String source = `module app;
constset KeyFlags : uint {
  SPACE = 32,
  RETURN = 13
}

cenum Status {
  OK = 0,
  FAIL = 1
}
`;

	AnalyzerContext* ctx = context::create(tmem);
	bool success = context::process(ctx, source, "test_constset.c3");
	assert(success);

	Module* mod = ctx.modules.get("app")!!;
	test::eq(mod.nodes.len(), 3);

	Node* n1 = mod.nodes[1];
	test::eq(n1.kind, NodeKind.ENUM_DECL);
	EnumDecl* ed1 = n1.as(EnumDecl);
	test::eq(ed1.name.text, "KeyFlags");
	test::eq(ed1.variants.len, 2);

	Node* n2 = mod.nodes[2];
	test::eq(n2.kind, NodeKind.ENUM_DECL);
	EnumDecl* ed2 = n2.as(EnumDecl);
	test::eq(ed2.name.text, "Status");
	test::eq(ed2.variants.len, 2);
}

fn void test_faultconst_and_excuse_keywords()
{
	String source = `module app;
faultconst ERR_IO, ERR_NET;
excuse MALFORMED_REQUEST, OUT_OF_BOUNDS;

fn void? check() {
  return ERR_IO~;
}
`;

	AnalyzerContext* ctx = context::create(tmem);
	bool success = context::process(ctx, source, "test_faultconst.c3");
	assert(success);

	Module* mod = ctx.modules.get("app")!!;
	test::eq(mod.nodes.len(), 4);

	Node* n1 = mod.nodes[1];
	test::eq(n1.kind, NodeKind.FAULTDEF_DECL);
	FaultdefDecl* fd1 = n1.as(FaultdefDecl);
	test::eq(fd1.faults.len, 2);
	test::eq(fd1.faults[0].as(FaultDecl).name.text, "ERR_IO");

	Node* n2 = mod.nodes[2];
	test::eq(n2.kind, NodeKind.FAULTDEF_DECL);
	FaultdefDecl* fd2 = n2.as(FaultdefDecl);
	test::eq(fd2.faults.len, 2);
	test::eq(fd2.faults[0].as(FaultDecl).name.text, "MALFORMED_REQUEST");
}

fn void test_attrgroup_and_attrmacro_keywords()
{
	String source = `module app;
attrgroup @FastCall = @inline, @noreturn;
attrmacro @TagField(val) = @tag("field_tag", val);

struct Foo {
  int x @TagField(10);
}
fn void exit_now() @FastCall {}
`;

	AnalyzerContext* ctx = context::create(tmem);
	bool success = context::process(ctx, source, "test_attrgroup.c3");
	assert(success);

	Module* mod = ctx.modules.get("app")!!;
	test::eq(mod.nodes.len(), 5);

	Node* n1 = mod.nodes[1];
	test::eq(n1.kind, NodeKind.ATTRDEF_DECL);
	AttrdefDecl* ad1 = n1.as(AttrdefDecl);
	test::eq(ad1.name.text, "@FastCall");

	Node* n2 = mod.nodes[2];
	test::eq(n2.kind, NodeKind.ATTRDEF_DECL);
	AttrdefDecl* ad2 = n2.as(AttrdefDecl);
	test::eq(ad2.name.text, "@TagField");
}

fn void test_ct_feat_keyword()
{
	String source = `module app;
fn void run() {
  $if $feat(WIN32):
    int os_type = 1;
  $else
    int os_type = 2;
  $endif
}
`;

	AnalyzerContext* ctx = context::create(tmem);
	bool success = context::process(ctx, source, "test_feat.c3");
	assert(success);
}

fn void test_lsp_hover_and_def_on_experimental_keywords()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module test_app;
distinct NativeId = ulong;
constset KeyCodes : uint {
  KEY_ESC = 27
}
excuse BAD_INPUT;

fn void run(NativeId id, KeyCodes key) {
  if (key == KEY_ESC) return;
}
`;

	proj.workspace.process_file("/virtual/exp_lsp.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/exp_lsp.c3");
	defer doc_uri.free();
	// 1. Hover on `NativeId` (line 7, char 15) -> shows "typedef NativeId = ulong"
	LspPosition id_pos = {.line = 7,.character = 15 };
	String h_id = hover::hover(&proj, doc_uri, id_pos)!!;
	assert(h_id.contains("typedef NativeId = ulong"));
	// 2. Go to definition on `KEY_ESC` (line 8, char 14) -> jumps to line 3
	LspPosition key_pos = {.line = 8,.character = 14 };
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, key_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 3);
	// 3. Document symbols outline
	SymbolInformation[] syms = document_symbols::get_document_symbols(&proj, doc_uri)!!;
	assert(syms.len >= 5);
	bool found_distinct = false;
	bool found_constset = false;
	bool found_excuse = false;
	foreach (s : syms)
	{
		if (s.name == "NativeId") found_distinct = true;
		if (s.name == "KeyCodes") found_constset = true;
		if (s.name == "BAD_INPUT") found_excuse = true;
	}
	assert(found_distinct);
	assert(found_constset);
	assert(found_excuse);
}
