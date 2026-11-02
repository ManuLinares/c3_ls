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
    test::eq(create_item.insertText, "create($1);");
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