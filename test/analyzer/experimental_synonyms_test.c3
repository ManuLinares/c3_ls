module experimental_synonyms_test @test;
import analyzer, lsp, uri, std::io;

fn void test_constset_keyword()
{
	String source = `module app;
constset KeyFlags : uint {
  SPACE = 32,
  RETURN = 13
}
`;

	AnalyzerContext* ctx = context::create(tmem);
	bool success = context::process(ctx, source, "test_constset.c3");
	assert(success);

	Module* mod = ctx.modules.get("app")!!;
	test::eq(mod.nodes.len(), 2);

	Node* n1 = mod.nodes[1];
	test::eq(n1.kind, NodeKind.ENUM_DECL);
	EnumDecl* ed1 = n1.as(EnumDecl);
	test::eq(ed1.name.text, "KeyFlags");
	test::eq(ed1.variants.len, 2);
}

fn void test_excuse_keyword()
{
	String source = `module app;
excuse MALFORMED_REQUEST, OUT_OF_BOUNDS;

fn void? check() {
  return MALFORMED_REQUEST~;
}
`;

	AnalyzerContext* ctx = context::create(tmem);
	bool success = context::process(ctx, source, "test_faultconst.c3");
	assert(success);

	Module* mod = ctx.modules.get("app")!!;
	test::eq(mod.nodes.len(), 3);

	Node* n1 = mod.nodes[1];
	test::eq(n1.kind, NodeKind.FAULTDEF_DECL);
	FaultdefDecl* fd1 = n1.as(FaultdefDecl);
	test::eq(fd1.faults.len, 2);
	test::eq(fd1.faults[0].as(FaultDecl).name.text, "MALFORMED_REQUEST");
}

fn void test_attrmacro_keyword()
{
	String source = `module app;
attrmacro @TagField(val) = @tag("field_tag", val);

struct Foo {
  int x @TagField(10);
}
`;

	AnalyzerContext* ctx = context::create(tmem);
	bool success = context::process(ctx, source, "test_attrgroup.c3");
	assert(success);

	Module* mod = ctx.modules.get("app")!!;
	test::eq(mod.nodes.len(), 3);

	Node* n1 = mod.nodes[1];
	test::eq(n1.kind, NodeKind.ATTRDEF_DECL);
	AttrdefDecl* ad1 = n1.as(AttrdefDecl);
	test::eq(ad1.name.text, "@TagField");
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
typedef NativeId = ulong;
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
	LspLocation[] locs = definition::goto_definition(&proj, doc_uri, key_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 3);
	// 3. Document symbols outline
	SymbolInformation[] syms = symbols::get_document_symbols(&proj, doc_uri)!!;
	assert(syms.len >= 5);
	bool found_typedef = false;
	bool found_constset = false;
	bool found_excuse = false;
	foreach (s : syms)
	{
		if (s.name == "NativeId") found_typedef = true;
		if (s.name == "KeyCodes") found_constset = true;
		if (s.name == "BAD_INPUT") found_excuse = true;
	}
	assert(found_typedef);
	assert(found_constset);
	assert(found_excuse);
}
