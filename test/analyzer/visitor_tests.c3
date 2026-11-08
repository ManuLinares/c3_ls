module visitor_tests;

import analyzer::core;
import analyzer::core::ast;
import analyzer::cursor;
import std::collections::list;

fn ChildVisitResult count_visit(Node* node, Node* parent, void* user_data)
{
	if (!node) return CONTINUE;
	List{Node*}* visited = (List{Node*}*)user_data;
	assert(!visited.contains(node), "%s at %s visited twice", node.kind, node.range);
	visited.push(node);
	return RECURSE;
}

fn void every_node_visited_once() @test
{
	String src = `module t;
struct Outer
{
	int a, b;
	struct inner_a
	{
		int x;
		struct deep { int y; }
	}
	union inner_b { int i; float f; }
	bitstruct flags : char { bool on : 0; }
}
fn void f()
{
	int c, d;
}
fn void Outer.method(&self) {}
macro void Outer.mac(&self) {}
`;
	AnalyzerContext* context = context::create(tmem);
	assert(context::process(context, src, "visit.c3"));
	SourceFile* sf = context.files.get("visit.c3")!!;

	List{Node*} visited;
	visited.tinit();
	foreach (stmt : sf.ast.statements)
	{
		if (stmt) cursor::visit(stmt, null, { .on_enter = &count_visit }, &visited);
	}
}
