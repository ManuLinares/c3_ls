module lsp::semantic_tokens_test @test;

import lsp::core;
import lsp::analysis::semantic_tokens;
import lsp;
import uri;
import std::io;
import analyzer::core::constants;

fn void test_semantic_tokens_generation()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module my_tokens;\nconst int MAX_COUNT = 100;\nfn void process_item(int id) {\n  int val = id * 2;\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/tokens.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/tokens.c3", source);

	SemanticTokensResult res = semantic_tokens::compute_semantic_tokens(&proj, doc_uri)!!;
	assert(res.data.len > 0);
	assert(res.data.len % 5 == 0);
}

fn void test_semantic_tokens_delta_invariants()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module delta_test;\nstruct Foo {\n  int a;\n  float b;\n}\nfn void foo() {}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/delta.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/delta.c3", source);

	SemanticTokensResult res = semantic_tokens::compute_semantic_tokens(&proj, doc_uri)!!;
	assert(res.data.len >= 15);

	for (sz i = 0; i < res.data.len; i += 5)
	{
		uint len = res.data[i + 2];
		uint token_type = res.data[i + 3];

		assert(len > 0);
		assert(token_type < 21);
	}
}

fn void test_semantic_tokens_operators_and_comments()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "// Line comment\nfn int calc() {\n  return 10 + 20 * 3;\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/ops.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/ops.c3", source);

	SemanticTokensResult res = semantic_tokens::compute_semantic_tokens(&proj, doc_uri)!!;
	assert(res.data.len > 0);

	bool found_op = false;
	bool found_num = false;
	for (sz i = 0; i < res.data.len; i += 5)
	{
		if (res.data[i + 3] == 20) found_op = true;
		if (res.data[i + 3] == 19) found_num = true;
	}
	assert(found_op);
	assert(found_num);
}

fn void test_semantic_tokens_readonly_modifier_on_constants()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module app;\nconst int BUFFER_CAP = 1024;\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/const_token.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/const_token.c3", source);

	SemanticTokensResult res = semantic_tokens::compute_semantic_tokens(&proj, doc_uri)!!;
	assert(res.data.len > 0);

	bool found_readonly_const = false;
	for (sz i = 0; i < res.data.len; i += 5)
	{
		uint token_type = res.data[i + 3];
		uint token_mods = res.data[i + 4];

		if (token_type == 10 && (token_mods & (1 << 2)) != 0)  // enumMember / constant with readonly bit
		{
			found_readonly_const = true;
		}
	}
	assert(found_readonly_const);
}

fn void test_semantic_tokens_base_types_and_numbers()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	DString src = dstring::temp();
	src.append("module t;\nfn void main()\n{\n");
	foreach (i, p : PrimitiveType::values)
	{
		if (p.name != "void" && p.name != "untypedlist") src.appendf("\t%s v%d;\n", p.name, i);
	}
	src.append("\t$assert $Typeof({ 1, 2 }) == untypedlist;\n");
	src.append("\tint a = 10;\n\tint b = 0x1F;\n\tint c = 0o17;\n\tint d = 0b101;\n\tdouble e = 1.5;\n\tdouble g = 0x1.8p1;\n}\n");
	String source = src.str_view();
	Uri doc_uri = uri::from_file_path(tmem, "/virtual/base_types.c3");
	proj.workspace.process_file("/virtual/base_types.c3", source);

	SemanticTokensResult res = semantic_tokens::compute_semantic_tokens(&proj, doc_uri)!!;
	String[] lines = source.tsplit("\n");
	uint line = 0;
	uint col = 0;
	int types = 0;
	int numbers = 0;
	bool untyped_list_seen;
	for (usz k = 0; k < res.data.len; k += 5)
	{
		if (res.data[k] != 0) col = 0;
		line += res.data[k];
		col += res.data[k + 1];
		String text = lines[line][col : res.data[k + 2]];
		uint kind = res.data[k + 3];
		if (text == "fn") assert(kind == 15, "fn: %d", kind);
		if (text == "untypedlist")
		{
			assert(kind == 1, "untypedlist: %d", kind);
			untyped_list_seen = true;
		}
		if (text[0].is_digit())
		{
			assert(kind == 19, "%s: %d", text, kind);
			numbers++;
		}
		foreach (p : PrimitiveType::values)
		{
			if (text == p.name)
			{
				assert(kind == 1, "%s: %d", text, kind);
				types++;
			}
		}
	}
	assert(untyped_list_seen);
	assert(numbers == 8, "%d numbers", numbers);
	assert(types == PrimitiveType::values.len + 6, "%d types", types);
}
