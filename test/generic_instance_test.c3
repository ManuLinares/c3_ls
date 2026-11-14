module lsp::generic_instance_test;

import lsp, lsp::analysis::completion, uri;

const String SOURCE = `
module app::queue;
struct Box <Type>
{
	Type value;
}
fn Type? Box.first(&self) => self.value;
typedef Queue <Type> = inline Box{Type};

module app::bag <Type>;
struct Bag
{
	Type item;
}
fn Type Bag.get(&self) => self.item;

module app::main;
import app::queue, app::bag;
struct Stream
{
	int id;
}
fn void Stream.on_timer(&self) {}
struct Timer
{
	int due;
	Stream* stream;
}
Queue{Timer} timers;
Bag{Timer} bag;
fn void? run_loop() {}
fn void fire()
{
	while (try t = timers.first())
	{
		t.stream.on_timer();
	}
	int d = bag.get().due + timers.value.due;
	if (catch run_loop()) return;
}
`;

fn LspPosition at(String needle, sz offset = 0)
{
	sz index = SOURCE.index_of(needle)!!;
	String before = SOURCE[:index];
	sz line_start = (before.rindex_of_char('\n') ?? -1) + 1;
	return { .line = (uint)before.count("\n"), .character = (uint)(index - line_start + offset) };
}

macro @with_project(; @body(LspProject* proj, Uri u))
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/gen.c3", SOURCE);
	@body(&proj, uri::from_file_path(tmem, "/virtual/gen.c3"));
}

fn String hover_at(LspProject* proj, Uri u, String needle, sz offset = 0) => hover::hover(proj, u, at(needle, offset)) ?? "";

fn void hover_substitutes_generic_arguments() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		assert(hover_at(proj, u, "t = timers").contains("try Timer t"));
		assert(hover_at(proj, u, "stream.on", 1).contains("Stream* stream"));
		assert(hover_at(proj, u, "on_timer();").contains("fn void Stream.on_timer(&self)"));
		assert(hover_at(proj, u, "due +").contains("int due"));
		assert(hover_at(proj, u, "due;").contains("int due"));
	};
}

fn void definition_through_generic_instance() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		LspLocation[] locs = definition::goto_definition(proj, u, at("on_timer();"))!!;
		assert(locs.len == 1 && locs[0].range.start.line == at("on_timer(&self)").line);
	};
}

fn void completion_through_generic_instance() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		LspPosition pos = at("due +");
		CompletionItem[] items = completion::resolve(proj, u, pos)!!;
		bool found;
		foreach (item : items) if (item.label == "due") found = true;
		assert(found);
	};
}

fn void hover_on_catch_call() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		assert(hover_at(proj, u, "run_loop())").contains("fn void? run_loop()"));
	};
}
