module lsp::scratch_test @test;

import lsp::core;
import lsp::analysis::completion;
import lsp;
import uri;
import std::io;

const String REPRO_SOURCE = `module game;

struct CppPtr { void* p; }
struct PhysicsEnginePtr { CppPtr ptr; }
struct PhysicsScenePtr { CppPtr ptr; }
struct PhysicsActorPtr { CppPtr ptr; }
struct GameObjectPtr { CppPtr ptr; }
struct Vec3 { float x, y, z; }

struct Context {
    PhysicsEnginePtr engine;
    PhysicsScenePtr scene;
}
fn PhysicsEnginePtr Context.getPhysicsEngine(&self) => self.engine;
fn PhysicsScenePtr Context.getPrimaryPhysicsScene(&self) => self.scene;

struct PhysicsRamp { int id; }

fn void PhysicsRamp.create(
    &self,
    PhysicsEnginePtr physicsEngine,
    PhysicsScenePtr physicsScene,
    PhysicsActorPtr carRigidBody,
    GameObjectPtr carGameObject,
    Vec3 rampSize,
    Vec3 shapeOffset,
    Vec3 rampLocalPos,
    Vec3 rampRotationAxis)
{
}

struct Component {
    Context context;
    PhysicsRamp physicsRamp;
}

fn void Component.test_call(&self) {
    PhysicsEnginePtr physicsEngine = self.context.getPhysicsEngine();
    PhysicsScenePtr physicsScene = self.context.getPrimaryPhysicsScene();

    self.physicsRamp.cr
    self.physicsRamp.create();
    self.physicsRamp.create(physicsEng);
    self.physicsRamp.create(physicsEngine, phys);
}
`;

fn void test_user_repro_issue1_method_snippet_parentheses()
{
    LspProject proj;
    proj.init(mem);
    defer proj.free();

    proj.workspace.process_file("/virtual/repro.c3", REPRO_SOURCE);
    Uri doc_uri = uri::from_file_path(mem, "/virtual/repro.c3");
    defer doc_uri.free();

    // Line 40: `    self.physicsRamp.cr` (cursor at col 23)
    LspPosition pos = { .line = 40, .character = 23 };
    CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

    CompletionItem* create_item = null;
    foreach (&item : items)
    {
        if (item.label == "create")
        {
            create_item = item;
            break;
        }
    }

    assert(create_item != null, "Could not find 'create' in completion items");
    test::eq(create_item.insertText, "create(${1:physicsEngine}, ${2:physicsScene}, ${3:carRigidBody}, ${4:carGameObject}, ${5:rampSize}, ${6:shapeOffset}, ${7:rampLocalPos}, ${8:rampRotationAxis});");
    test::eq(create_item.insertTextFormat, InsertTextFormat.SNIPPET);
    // assert(create_item.command.has_value, "Expected command on function completion item");
    // test::eq(create_item.command.value.command, "editor.action.triggerParameterHints");
}

fn void test_user_repro_issue2_empty_parens_suppresses_locals()
{
    LspProject proj;
    proj.init(mem);
    defer proj.free();

    proj.workspace.process_file("/virtual/repro.c3", REPRO_SOURCE);
    Uri doc_uri = uri::from_file_path(mem, "/virtual/repro.c3");
    defer doc_uri.free();

    // Line 41: `    self.physicsRamp.create();` with cursor inside `(|)` at col 28
    LspPosition pos = { .line = 41, .character = 28 };
    CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

    bool found_local_var = false;
    bool found_named_arg = false;
    String local_var_sort = "";
    String other_local_sort = "";

    foreach (item : items)
    {
        if (item.label == "physicsEngine" && item.kind == VARIABLE)
        {
            found_local_var = true;
            local_var_sort = item.sortText;
        }
        if (item.label == "physicsScene" && item.kind == VARIABLE)
        {
            other_local_sort = item.sortText;
        }
        if (item.label == "physicsEngine:") found_named_arg = true;
    }

    test::eq(found_local_var, true);
    test::eq(found_named_arg, true);
    test::eq(local_var_sort, "0000_physicsEngine");
    test::eq(other_local_sort, "0003_physicsScene");
    assert(local_var_sort.compare_to(other_local_sort) < 0);
}

fn void test_user_repro_issue3_first_arg_misses_local_var()
{
    LspProject proj;
    proj.init(mem);
    defer proj.free();

    proj.workspace.process_file("/virtual/repro.c3", REPRO_SOURCE);
    Uri doc_uri = uri::from_file_path(mem, "/virtual/repro.c3");
    defer doc_uri.free();

    // Line 42: `    self.physicsRamp.create(physicsEng);` (cursor after physicsEng at col 38)
    LspPosition pos = { .line = 42, .character = 38 };
    CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

    bool found_local_var = false;
    bool found_type = false;

    foreach (item : items)
    {
        if (item.label == "physicsEngine" && item.kind == VARIABLE) found_local_var = true;
        if (item.label == "PhysicsEnginePtr" && (item.kind == STRUCT || item.kind == CLASS)) found_type = true;
    }

    test::eq(found_type, true);
    test::eq(found_local_var, true);
}

fn void test_user_repro_issue4_second_arg_named_arg_colon_ranks_above_local()
{
    LspProject proj;
    proj.init(mem);
    defer proj.free();

    proj.workspace.process_file("/virtual/repro.c3", REPRO_SOURCE);
    Uri doc_uri = uri::from_file_path(mem, "/virtual/repro.c3");
    defer doc_uri.free();

    // Line 43: `    self.physicsRamp.create(physicsEngine, phys);` (cursor after phys at col 47)
    LspPosition pos = { .line = 43, .character = 47 };
    CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

    String named_arg_sort = "";
    String local_var_sort = "";

    foreach (item : items)
    {
        if (item.label == "physicsScene:")
        {
            named_arg_sort = item.sortText;
        }
        if (item.label == "physicsScene" && item.kind == VARIABLE)
        {
            local_var_sort = item.sortText;
        }
    }

    assert(named_arg_sort.len > 0, "Named argument 'physicsScene:' was not found");
    assert(local_var_sort.len > 0, "Local variable 'physicsScene' was not found");

    test::eq(local_var_sort, "0000_physicsScene");
    test::eq(named_arg_sort, "0002_physicsScene");
    assert(local_var_sort.compare_to(named_arg_sort) < 0);
}
fn void bindings_match_like_locals()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module t;\nfn int? g() => 1;\nfn void f(int[] arr)\n{\n\tint local_value;\n\tforeach (idx_value, item_value : arr)\n\t{\n\t\tif (try try_value = g())\n\t\t{\n\t\t\tval\n\t\t}\n\t}\n}\n";
	proj.workspace.process_file("/virtual/bindings.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/bindings.c3");
	defer doc_uri.free();

	DString labels;
	labels.tinit();
	foreach (item : completion::resolve(&proj, doc_uri, { .line = 9, .character = 6 })!!) labels.appendf("%s ", item.label);
	String got = labels.str_view();
	foreach (name : (String[]){ "local_value", "idx_value", "item_value", "try_value" })
	{
		assert(got.contains(name), "%s missing from: %s", name, got);
	}
}

fn void designator_after_escaped_backslash_string()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module t;\nstruct Foo { String a; int b; int c; }\nfn void f()\n{\n\tFoo x = { .a = \"\\\\\", .b = 1, . };\n}\n";
	proj.workspace.process_file("/virtual/designator.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/designator.c3");
	defer doc_uri.free();

	DString labels;
	labels.tinit();
	foreach (item : completion::resolve(&proj, doc_uri, { .line = 4, .character = 31 })!!) labels.appendf("%s ", item.label);
	test::eq(labels.str_view().trim(), "c");
}

fn void designator_ignores_comments_and_strings()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module t;\nstruct Foo { String a; int b; int c; }\nfn void f()\n{\n\tFoo x = { .a = \"y\" /* } */, . };\n\tFoo y = { .a = \"}\" /* .b */, . };\n}\n";
	proj.workspace.process_file("/virtual/designator_comments.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/designator_comments.c3");
	defer doc_uri.free();

	foreach (LspPosition pos : (LspPosition[]){ { 4, 30 }, { 5, 31 } })
	{
		DString labels;
		labels.tinit();
		foreach (item : completion::resolve(&proj, doc_uri, pos)!!) labels.appendf("%s ", item.label);
		test::eq(labels.str_view().trim(), "b c");
	}
}

fn void named_argument_completion_ignores_comments()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module t;\nfn void show(String a, int b, int c) {}\nfn void main()\n{\n\tshow(\"x\" /* , */, );\n}\n";
	proj.workspace.process_file("/virtual/named_args.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/named_args.c3");
	defer doc_uri.free();

	DString labels;
	labels.tinit();
	foreach (item : completion::resolve(&proj, doc_uri, { .line = 4, .character = 19 })!!) labels.appendf("%s ", item.label);
	assert(labels.str_view().contains("b:"), "b: missing from: %s", labels.str_view());
}

fn void assignment_expected_type_ignores_comments()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module t;\nenum Color { RED, GREEN }\nfn void f()\n{\n\tColor c /* note */ = \n}\n";
	proj.workspace.process_file("/virtual/assign_comment.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/assign_comment.c3");
	defer doc_uri.free();

	CompletionItem[] items = completion::resolve(&proj, doc_uri, { .line = 4, .character = 22 })!!;
	assert(items.len > 1 && items[0].label == "RED" && items[1].label == "GREEN", "%s %s", items[0].label, items[1].label);
}

fn void locals_of_closed_blocks_not_offered()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module t;\nfn void f()\n{\n\t{\n\t\tint closed_value = 1;\n\t}\n\tclosed\n}\n";
	proj.workspace.process_file("/virtual/closed_block.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/closed_block.c3");
	defer doc_uri.free();

	foreach (item : completion::resolve(&proj, doc_uri, { .line = 6, .character = 7 })!!)
	{
		assert(item.label != "closed_value", "local of a closed block offered");
	}
}

fn void try_binding_not_offered_in_else()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module t;\nfn int? g() => 1;\nfn void f()\n{\n\tif (try unwrapped = g())\n\t{\n\t}\n\telse\n\t{\n\t\tunwr\n\t}\n}\n";
	proj.workspace.process_file("/virtual/try_else_completion.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/try_else_completion.c3");
	defer doc_uri.free();

	foreach (item : completion::resolve(&proj, doc_uri, { .line = 9, .character = 6 })!!)
	{
		assert(item.label != "unwrapped", "try binding offered in else");
	}
}

fn void catch_binding_offered_in_else()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module t;\nfn int? g() => 1;\nfn void f()\n{\n\tif (catch caught = g())\n\t{\n\t}\n\telse\n\t{\n\t\tcaug\n\t}\n}\n";
	proj.workspace.process_file("/virtual/catch_else_completion.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/catch_else_completion.c3");
	defer doc_uri.free();

	bool found;
	foreach (item : completion::resolve(&proj, doc_uri, { .line = 9, .character = 6 })!!) found |= item.label == "caught";
	assert(found, "catch binding missing in else");
}

fn void foreach_binding_ranked_by_expected_type()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module t;\nfn void f(int[] arr)\n{\n\tforeach (int each_value : arr)\n\t{\n\t\tint x = \n\t}\n}\n";
	proj.workspace.process_file("/virtual/foreach_rank.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/foreach_rank.c3");
	defer doc_uri.free();

	foreach (item : completion::resolve(&proj, doc_uri, { .line = 5, .character = 10 })!!)
	{
		if (item.label == "each_value")
		{
			test::eq(item.sortText, "0000_each_value");
			return;
		}
	}
	unreachable("each_value not offered");
}

fn void unclosed_parameter_list_offers_types_only()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module t;\nint my_global_var;\nstruct MyStruct { int x; }\nfn void f(My\n";
	proj.workspace.process_file("/virtual/unclosed_params.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/unclosed_params.c3");
	defer doc_uri.free();

	DString labels;
	labels.tinit();
	foreach (item : completion::resolve(&proj, doc_uri, { .line = 3, .character = 12 })!!) labels.appendf("%s ", item.label);
	test::eq(labels.str_view().trim(), "MyStruct");
}

fn void member_completion_after_call_with_bracket_in_string()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module t;\nstruct Point { int px; int py; }\nfn Point make(String s) => {};\nfn void f()\n{\n\tint v = make(\")\").\n}\n";
	proj.workspace.process_file("/virtual/base_string.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/base_string.c3");
	defer doc_uri.free();

	DString labels;
	labels.tinit();
	foreach (item : completion::resolve(&proj, doc_uri, { .line = 5, .character = 19 })!!) labels.appendf("%s ", item.label);
	test::eq(labels.str_view().trim(), "px py");
}
