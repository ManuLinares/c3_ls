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
<*
 @require x > 0
*>
fn int g(int x) => x;
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

fn void identifier_set_holds_every_identifier_form() @test
{
	String src = `module t;
attrdef @Hot = @inline;
macro @wrap(#expr, $count, $Type) @builtin { return #expr; }
const int MAX = 1;
struct Foo { int foo; }
fn void f() @Hot {}
`;
	AnalyzerContext* context = context::create(tmem);
	context::process(context, src, "idents.c3");
	SourceFile* sf = context.files.get("idents.c3")!!;
	String[12] expected = { "t", "@Hot", "@inline", "@wrap", "#expr", "$count", "$Type", "@builtin", "MAX", "Foo", "foo", "f" };
	foreach (name : expected)
	{
		assert(sf.mentions(name), "'%s' missing", name);
	}
	assert(!sf.mentions("int"));
	assert(!sf.mentions("1"));
}

fn ChildVisitResult collect_visit(Node* node, Node* parent, void* user_data)
{
	if (!node) return CONTINUE;
	((List{Node*}*)user_data).push(node);
	return RECURSE;
}

fn void every_parsed_node_reachable() @test
{
	String src = `module t;
faultdef BAD @deprecated;
attrdef @Hot(x) = @inline;
$assert 1 + 1 == 2;
<*
 @require a > 0
 @ensure return > 0
*>
fn int pos(int a) { return a; }
macro int @sum(...)
{
	int total = 0;
	$for var $i = 0; $i < $vaarg.len; $i++:
		total += $vaarg[$i];
	$endfor
	return total;
}
fn void main()
{
	int v = 3;
	assert(v > 0, "v is %d", v);
	$assert int::size == 4 : "size";
	$if false:
		$error "never";
	$endif
	int s = @sum(1, 2);
	int line = $$LINE;
}
`;
	AnalyzerContext* context = context::create(tmem);
	assert(context::process(context, src, "reach.c3"));
	SourceFile* sf = context.files.get("reach.c3")!!;

	List{Node*} visited;
	visited.tinit();
	foreach (stmt : sf.ast.statements)
	{
		if (stmt) cursor::visit(stmt, null, { .on_enter = &collect_visit }, &visited);
	}
	DString missing = dstring::temp();
	foreach (node : sf.ast.nodes)
	{
		if (node.kind != ERROR && !visited.contains(node)) missing.appendf("%s@%d:%d ", node.kind, node.range.start.line, node.range.start.column);
	}
	assert(missing.len() == 0, "unreachable: %s", missing);
}
