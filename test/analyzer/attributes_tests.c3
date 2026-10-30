module attributes_tests @test;

import parser_tests;

import analyzer::parser;
import analyzer::core;
import analyzer::sema;
import lsp::analysis::goto_definition;
import lsp::analysis::hover;
import lsp::analysis::completion;
import lsp;
import lsp::core;
import uri;
import std::io;
import std::collections::list;
import std::io::file;
import std::io::path;

fn void module_private_test_weak_if()
{
	String source_code = `
		module hello @private @test @weak @if(1 == 1 && 2 == 2);
	`;
	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test");
	test::eq(success, true);

	Module* mod = context.modules.get("hello")!!;

	ModuleDecl* module_node = mod.module_decls[0];
	test::eq(module_node.visibility, Visibility.PRIVATE);

	test::eq(module_node.attributes.len, 4);
	// @private
	test::eq(parser_tests::@attr(module_node, 0).attribute_kind, AttributeKind.PRIVATE);
	// @weak
	test::eq(parser_tests::@attr(module_node, 1).attribute_kind, AttributeKind.TEST);
	// @test
	test::eq(parser_tests::@attr(module_node, 2).attribute_kind, AttributeKind.WEAK);
	// @if(1 == 1 && 2 == 2)
	AttributeDecl* attr = parser_tests::@attr(module_node, 3);
	test::eq(attr.attribute_kind, AttributeKind.IF);
	test::eq(attr.exprs.len, 1);
	// (1 == 1 && 2 == 2)
	BinaryExpr* and_expr = attr.exprs[0].as(BinaryExpr);
	test::eq(and_expr.op, OperatorKind.OP_AND);
	// 1 == 1
	BinaryExpr* left_eq_expr = and_expr.left.as(BinaryExpr);
	test::eq(left_eq_expr.left.as(LiteralExpr).integer, 1u);
	test::eq(left_eq_expr.right.as(LiteralExpr).integer, 1u);
	// 2 == 2
	BinaryExpr* right_eq_expr = and_expr.right.as(BinaryExpr);
	test::eq(right_eq_expr.left.as(LiteralExpr).integer, 2u);
	test::eq(right_eq_expr.right.as(LiteralExpr).integer, 2u);
}

fn void module_tag_if()
{
	String source_code = `
		module hello @tag("my_tag", "my_value") @if($feature(MY_FEATURE));
	`;
	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test");
	test::eq(success, true);

	Module* mod = context.modules.get("hello")!!;

	ModuleDecl* module_decl = mod.module_decls[0];
	test::eq(module_decl.visibility, Visibility.PUBLIC);
	test::eq(module_decl.attributes.len, 2);
	// @tag("my_tag", "my_value")
	AttributeDecl* attr = parser_tests::@attr(module_decl, 0);
	test::eq(attr.attribute_kind, AttributeKind.TAG);
	test::eq(attr.exprs.len, 2);
	// "my_tag"
	LiteralExpr* lit_expr = attr.exprs[0].as(LiteralExpr);
	test::eq(lit_expr.literal_kind, LiteralKind.STRING_LITERAL);
	test::eq(lit_expr.string, "my_tag");
	// "my_value"
	lit_expr = attr.exprs[1].as(LiteralExpr);
	test::eq(lit_expr.literal_kind, LiteralKind.STRING_LITERAL);
	test::eq(lit_expr.string, "my_value");
	// end @tag()
	// @if($feature(MY_FEATURE))
	attr = parser_tests::@attr(module_decl, 1);
	test::eq(attr.attribute_kind, AttributeKind.IF);
	test::eq(attr.exprs.len, 1);
	CtFeatureExpr* feat          = attr.exprs[0].as(CtFeatureExpr);
	IdentExpr* callee_ident_expr = feat.expr_list[0].as(IdentExpr);
	test::eq(callee_ident_expr.ident.text, "MY_FEATURE");
	// end @if()
}

fn void function_if()
{
	String source_code = `
		module hello;
		fn void greet() @private @if($feature(MY_FEATURE)) {}
	`;
	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test");
	test::eq(success, true);

	Module* mod = context.modules.get("hello")!!;
	test::ne(mod, null);

	FunctionInfo* func_info = context.registry.functions.get("hello::greet")!!;
	test::eq(func_info.mod, "hello");
	Node* node = func_info.node;
	test::eq(node.kind, NodeKind.FN_DECL);
	test::eq(node.visibility, Visibility.PRIVATE);

	FnDecl* fn_decl = node.as(FnDecl);
	test::eq(fn_decl.attributes.len, 2);
	// @private
	AttributeDecl* attr = parser_tests::@attr(fn_decl, 0);
	test::eq(attr.attribute_kind, AttributeKind.PRIVATE);
	test::eq(attr.exprs.len, 0);
	// @if($feature(MY_FEATURE))
	attr = parser_tests::@attr(fn_decl, 1);
	test::eq(attr.attribute_kind, AttributeKind.IF);
	test::eq(attr.exprs.len, 1);

	CtFeatureExpr* feat          = attr.exprs[0].as(CtFeatureExpr);
	IdentExpr* callee_ident_expr = feat.expr_list[0].as(IdentExpr);
	test::eq(callee_ident_expr.ident.text, "MY_FEATURE");
}

fn void const_var_private_if()
{
	String source_code = `
		module hello;
		
		const MY_CONST @private @if($feature(MY_FEATURE)) = 1;
		void* my_var @private @if($feature(MY_FEATURE)) = null;
	`;
	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test");
	test::eq(success, true);

	Module* mod = context.modules.get("hello")!!;
	test::@check(mod.nodes.len() > 0);

	int var_decl_count = 0;
	foreach (node : mod.nodes)
	{
		if (node.kind != VAR_DECL) continue;

		var_decl_count++;
		VarDecl* var_decl = node.as(VarDecl);

		test::eq(node.visibility, Visibility.PRIVATE);
		test::eq(node.flags.has_attributes, true);

		String var_name = var_decl.name.text;

		test::eq(var_decl.var_kind, VarDeclKind.VAR_GLOBAL);
		test::eq(var_decl.attributes.len, 2);
		if (var_decl.var_flags.is_const)
		{
			test::eq(var_name, "MY_CONST");
		}
		else
		{
			test::eq(var_name, "my_var");
		}
		// @if($feature(MY_FEATURE))
		AttributeDecl* attr = parser_tests::@attr(var_decl, 1);
		test::eq(attr.attribute_kind, AttributeKind.IF);
		test::eq(attr.exprs.len, 1);
		// $feature()
		CtFeatureExpr* call          = attr.exprs[0].as(CtFeatureExpr);
		IdentExpr* callee_ident_expr = call.expr_list[0].as(IdentExpr);
		test::eq(callee_ident_expr.ident.text, "MY_FEATURE");
	}
	test::eq(var_decl_count, 2);
}

fn void op_overloads()
{
	String source_code = `
		module hello;
		struct Foo
		{	
			float a;
			double[] x;
		}

		fn Foo Foo.minus_float(self, float f) @operator(-) => { .a = self.a - f };
		fn Foo Foo.minus_double(self, double d) @operator(-) => { .a = self.a - d };
		fn Foo Foo.add(self, Foo other) @operator(+) => { .a = self.a + other.a };
		fn Foo Foo.add_self(&self, Foo other) @operator(+=)
		{
			self.a += other.a;
			return *self;
		}
		fn bool Foo.eq(self, Foo other) @operator(==)
		{
			return self.a == other.a;
		}
		fn double Foo.get(&self, sz i) @operator([])
		{
			return self.x[i];
		}
		fn double* Foo.get_ref(&self, sz i) @operator(&[])
		{
			return &self.x[i];
		}
		fn void Foo.set(&self, sz i, double new_val) @operator([]=)
		{
			return self.x[i] = new_val;
		}
	`;

	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test");
	test::eq(success, true);

	Module* mod = context.modules.get("hello")!!;
	int fn_decl_count = 0;
	foreach (node : mod.nodes)
	{
		if (node.kind != FN_DECL) continue;
		fn_decl_count++;

		FnDecl* fn_decl = node.as(FnDecl);
		String fn_name = fn_decl.name.text;
		test::eq(fn_decl.attributes.len, 1);

		AttributeDecl* attr = parser_tests::@attr(fn_decl, 0);
		test::eq(attr.attribute_kind, AttributeKind.OPERATOR);
		OverloadExpr* overload_expr = attr.exprs[0].as(OverloadExpr);
		switch (fn_name)
		{
			case "minus_float":
				test::eq(overload_expr.overload_kind, OverloadKind.OV_MINUS);
			case "minus_double":
				test::eq(overload_expr.overload_kind, OverloadKind.OV_MINUS);
			case "add":
				test::eq(overload_expr.overload_kind, OverloadKind.OV_PLUS);
			case "add_self":
				test::eq(overload_expr.overload_kind, OverloadKind.OV_PLUS_ASSIGN);
			case "eq":
				test::eq(overload_expr.overload_kind, OverloadKind.OV_EQUAL);
			case "get":
				test::eq(overload_expr.overload_kind, OverloadKind.OV_ELEMENT_AT);
			case "get_ref":
				test::eq(overload_expr.overload_kind, OverloadKind.OV_ELEMENT_REF);
			case "set":
				test::eq(overload_expr.overload_kind, OverloadKind.OV_ELEMENT_SET);
		}
	}
	test::eq(fn_decl_count, 8);
}

// attrmacro @HotInline defined on line 0 (0-indexed), col 10
// used on line 2 (0-indexed), col 30 (@operator(+) is 14 chars, space, then @HotInline)
fn void attrmacro_goto_definition()
{
	String code = `module attrtest;
attrmacro @HotInline = @inline, @nodiscard;
struct Vec { float x; float y; }
fn Vec Vec.add(self, Vec other) @operator(+) @HotInline { return { self.x + other.x, self.y + other.y }; }
`;

	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.workspace.process_file("/virtual/attrtest.c3", code);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/attrtest.c3");
	defer doc_uri.free();

	// cursor on @HotInline at line 3, col 45
	LspPosition use_pos = { .line = 3, .character = 45 };
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, use_pos)!!;
	test::eq(locs.len, 1);
	// should resolve to the attrmacro declaration on line 1
	test::eq(locs[0].range.start.line, 1u);
}

fn void attrmacro_hover()
{
	String code = `module attrtest2;
attrmacro @HotInline = @inline, @nodiscard;
struct Vec { float x; float y; }
fn Vec Vec.add(self, Vec other) @operator(+) @HotInline { return { self.x + other.x, self.y + other.y }; }
`;

	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.workspace.process_file("/virtual/attrtest2.c3", code);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/attrtest2.c3");
	defer doc_uri.free();

	// hover on @HotInline use site (line 3, col 45)
	LspPosition use_pos = { .line = 3, .character = 45 };
	String hover_res = hover::hover(&proj, doc_uri, use_pos)!!;
	assert(hover_res.contains("attrmacro"));
	assert(hover_res.contains("@HotInline"));
	assert(hover_res.contains("@inline"));
	assert(hover_res.contains("@nodiscard"));
}

fn void attrmacro_completion()
{
	String code = `module attrtest3;
attrmacro @HotInline = @inline, @nodiscard;
struct Vec { float x; float y; }
fn Vec Vec.add(self, Vec other) @operator(+) @Hot
`;

	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.workspace.process_file("/virtual/attrtest3.c3", code);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/attrtest3.c3");
	defer doc_uri.free();

	// cursor after "@Hot" on line 3, col 49
	LspPosition pos = { .line = 3, .character = 49 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found = false;
	foreach (item : items)
	{
		if (item.label == "@HotInline") { found = true; break; }
	}
	assert(found);
}

fn void builtin_attr_completion()
{
	// typing "@" on a function declaration — should offer built-in attributes
	String code = `module attrtest4;
fn void foo() @
`;

	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.workspace.process_file("/virtual/attrtest4.c3", code);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/attrtest4.c3");
	defer doc_uri.free();

	// cursor after "@" on line 1, col 15
	LspPosition pos = { .line = 1, .character = 15 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found_inline = false;
	bool found_nodiscard = false;
	bool found_inline_label = false;
	foreach (item : items)
	{
		if (item.label == "@inline")    { found_inline = true; }
		if (item.label == "@nodiscard") { found_nodiscard = true; }
	}
	assert(found_inline);
	assert(found_nodiscard);
}

fn void attrmacro_parameterized_hover()
{
	String code = `module attrtest5;
attrmacro @TagFoo(value) = @tag("foo", value);
fn void foo() @TagFoo("bar") {}
`;

	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.workspace.process_file("/virtual/attrtest5.c3", code);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/attrtest5.c3");
	defer doc_uri.free();

	LspPosition use_pos = { .line = 2, .character = 15 };
	String hover_res = hover::hover(&proj, doc_uri, use_pos)!!;
	assert(hover_res.contains("attrmacro"));
	assert(hover_res.contains("@TagFoo"));
	assert(hover_res.contains("value"));
	assert(hover_res.contains("@tag"));
	assert(hover_res.contains("\"foo\""));
}

fn void test_attribute_scope_excludes_callable_macros() @test
{
	String code = `module attrtest_scope;
attrmacro @HotInline = @inline, @nodiscard;
macro void @swap_values(#a, #b) {}

fn void foo() @
`;

	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.workspace.process_file("/virtual/attr_scope.c3", code);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/attr_scope.c3");
	defer doc_uri.free();

	LspPosition pos = { .line = 4, .character = 15 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found_hot_inline = false;
	bool found_inline = false;
	bool found_swap_macro = false;

	foreach (item : items)
	{
		if (item.label == "@HotInline")   found_hot_inline = true;
		if (item.label == "@inline")      found_inline = true;
		if (item.label == "@swap_values") found_swap_macro = true;
	}

	assert(found_hot_inline);
	assert(found_inline);
	assert(!found_swap_macro);
}

fn void test_execution_scope_excludes_declaration_attributes() @test
{
	String code = `module attrtest_exec;
attrmacro @HotInline = @inline;
macro void @swap_values(#a, #b) {}

fn void run() {
    @
}
`;

	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.workspace.process_file("/virtual/attr_exec.c3", code);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/attr_exec.c3");
	defer doc_uri.free();

	LspPosition pos = { .line = 5, .character = 5 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found_swap = false;
	bool found_packed = false;
	bool found_export = false;
	bool found_hot_inline = false;

	foreach (item : items)
	{
		if (item.label == "@swap_values") found_swap = true;
		if (item.label == "@packed")      found_packed = true;
		if (item.label == "@export")      found_export = true;
		if (item.label == "@HotInline")   found_hot_inline = true;
	}

	assert(found_swap);
	assert(!found_packed);
	assert(!found_export);
	assert(!found_hot_inline);
}

fn void test_target_aware_attribute_filtering() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String code = `module attrtest_targets;
import std::io @
struct MyData @
`;

	proj.workspace.process_file("/virtual/attr_targets.c3", code);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/attr_targets.c3");
	defer doc_uri.free();

	LspPosition imp_pos = { .line = 1, .character = 16 };
	CompletionItem[] imp_items = completion::resolve(&proj, doc_uri, imp_pos)!!;

	bool found_norecurse = false;
	bool found_packed_on_import = false;
	foreach (item : imp_items)
	{
		if (item.label == "@norecurse") found_norecurse = true;
		if (item.label == "@packed")    found_packed_on_import = true;
	}
	assert(found_norecurse);
	assert(!found_packed_on_import);

	LspPosition struct_pos = { .line = 2, .character = 15 };
	CompletionItem[] struct_items = completion::resolve(&proj, doc_uri, struct_pos)!!;

	bool found_packed = false;
	bool found_nodiscard = false;
	foreach (item : struct_items)
	{
		if (item.label == "@packed")    found_packed = true;
		if (item.label == "@nodiscard") found_nodiscard = true;
	}
	assert(found_packed);
	assert(!found_nodiscard);
}

fn void test_builtin_attribute_hover() @test
{
	String code = `module attrtest_hover;
struct Packet @packed {
    int id;
}
fn void run() @inline {}
`;

	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.workspace.process_file("/virtual/attr_hover.c3", code);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/attr_hover.c3");
	defer doc_uri.free();

	// 1. Hover on @packed (line 1, col 16)
	LspPosition packed_pos = { .line = 1, .character = 16 };
	String h_packed = hover::hover(&proj, doc_uri, packed_pos)!!;
	assert(h_packed.contains("attribute @packed"));
	assert(h_packed.contains("Sets struct/union member alignment to 1 byte."));

	// 2. Hover on @inline (line 4, col 16)
	LspPosition inline_pos = { .line = 4, .character = 16 };
	String h_inline = hover::hover(&proj, doc_uri, inline_pos)!!;
	assert(h_inline.contains("attribute @inline"));
	assert(h_inline.contains("Forces function or call-site inlining."));
}