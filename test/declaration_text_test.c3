module lsp::declaration_text_test;

import lsp, lsp::analysis::completion, uri;

const String SOURCE = `module app::kinds;
import std::io;

const String ICON = "a.svg"; // trailing
typedef Handle @constinit = inline int;
faultdef NOT_FOUND, BAD_INPUT;
struct Point (Printable) @align(16)
{
	int x;
	int y;
}
struct Wrapper
{
	inline Point base;
}
enum Color : char (String hex)
{
	RED { "f00" },
	GREEN { "0f0" },
}
enum Shade : char (Color base)
{
	RED { RED },
}
<*
 Doubles ``x``.
*>
macro int @twice(x) => x * 2;
fn sz? Point.to_format(&self, Formatter* f) @dynamic => f.printf("%d", self.x);
<*
 Sum of the coordinates and ``extra``.
*>
fn int Point.sum(&self, int extra = 2) @inline
{
	return self.x + self.y + extra;
}
fn void multi(
	int a,
	/* note */ int b, // trailing
	String c = "x")
{
}
extern fn int puts(char* s);
fn void use_all()
{
	static int calls = 0;
	Wrapper w;
	Handle h = 1;
	String s = ICON;
	fault f = NOT_FOUND;
	Color k = Color.RED;
	int n = w.base.sum() + calls + puts("x");
	multi(1, 2, "y");
	int t = @twice(3);
}
`;

<*
 Position of the first `needle` in SOURCE, moved `offset` characters right.
*>
fn LspPosition at(String needle, sz offset = 0)
{
	sz index = SOURCE.index_of(needle)!!;
	String before = SOURCE[:index];
	sz line_start = (before.rindex_of_char('\n') ?? -1) + 1;
	return { .line = (uint)before.count("\n"), .character = (uint)(index - line_start + offset) };
}

macro String @hover(LspProject* proj, String needle, sz offset = 0)
{
	Uri u = uri::from_file_path(tmem, "/virtual/kinds.c3");
	return hover::hover(proj, u, at(needle, offset))!!;
}

macro @with_project(; @body(LspProject* proj))
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/kinds.c3", SOURCE);
	@body(&proj);
}

fn void hover_renders_declarations_as_written() @test
{
	@with_project(; LspProject* proj)
	{
		assert(@hover(proj, "= ICON", 2).starts_with("```c3\nconst String ICON = \"a.svg\"\n```\nmodule `app::kinds`"));
		assert(@hover(proj, "Handle h").contains("```c3\ntypedef Handle @constinit = inline int\n```"));
		assert(@hover(proj, "= NOT_FOUND", 2).contains("```c3\nfault NOT_FOUND\n```"));
		assert(@hover(proj, "Wrapper w").contains("```c3\nstruct Wrapper\n```"));
		assert(@hover(proj, "Color.RED", 6).contains("```c3\nColor.RED { \"f00\" }\n```"));
		assert(@hover(proj, "Color k").contains("```c3\nenum Color : char (String hex)\n```"));
		assert(@hover(proj, "w.base", 2).contains("```c3\ninline Point base\n```"));
		assert(@hover(proj, "puts(\"x\")").contains("```c3\nextern fn int puts(char* s)\n```"));
		assert(@hover(proj, "base.sum", 5) == "```c3\nfn int Point.sum(&self, int extra = 2) @inline\n```\nmodule `app::kinds`\n\nSum of the coordinates and `extra`.");
		assert(@hover(proj, "multi(1").contains("```c3\nfn void multi(\n    int a,\n    int b,\n    String c = \"x\")\n```"));
	};
}

fn void hover_omits_module_for_locals() @test
{
	@with_project(; LspProject* proj)
	{
		assert(@hover(proj, "+ calls", 2) == "```c3\nstatic int calls = 0\n```");
	};
}

fn void hover_struct_header_keeps_interfaces_and_attributes() @test
{
	@with_project(; LspProject* proj)
	{
		assert(@hover(proj, "struct Point", 7).contains("```c3\nstruct Point (Printable) @align(16)\n```"));
	};
}

fn void completion_detail_is_one_line_signature_on_every_row() @test
{
	@with_project(; LspProject* proj)
	{
		Uri u = uri::from_file_path(tmem, "/virtual/kinds.c3");
		bool found_sum;
		foreach (item : completion::resolve(proj, u, at("base.sum", 5))!!)
		{
			if (item.label != "sum") continue;
			found_sum = true;
			assert(item.detail == "fn int Point.sum(&self, int extra = 2) @inline", "%s", item.detail);
			assert(item.labelDetails.description == item.detail, "%s", item.labelDetails.description);
		}
		assert(found_sum);
		bool found_multi;
		foreach (item : completion::resolve(proj, u, at("multi(1", 3))!!)
		{
			if (item.label != "multi") continue;
			found_multi = true;
			assert(item.detail == "fn void multi(int a, int b, String c = \"x\")", "%s", item.detail);
		}
		assert(found_multi);
	};
}

fn void signature_help_parameter_labels_are_in_label() @test
{
	@with_project(; LspProject* proj)
	{
		Uri u = uri::from_file_path(tmem, "/virtual/kinds.c3");
		SignatureHelpResult res = signature_help::signature_help(proj, u, at("multi(1", 6))!!;
		assert(res.signatures.len == 1);
		SignatureInformation sig = res.signatures[0];
		assert(sig.label == "fn void multi(int a, int b, String c = \"x\")", "%s", sig.label);
		assert(sig.parameters.len == 3);
		foreach (p : sig.parameters) assert(sig.label.contains(p.label), "%s", p.label);
	};
}

fn void hover_resolves_identifiers_in_enum_value_arguments() @test
{
	@with_project(; LspProject* proj)
	{
		String h = @hover(proj, "RED { RED }", 6);
		assert(h.starts_with("```c3\nColor.RED { \"f00\" }\n```"), "%s", h);
	};
}

fn void hover_shows_macro_expansion_after_docs() @test
{
	@with_project(; LspProject* proj)
	{
		String h = @hover(proj, "@twice(3)", 1);
		sz docs = h.index_of("Doubles `x`.")!!;
		sz expansion = h.index_of("**Macro Expansion:**")!!;
		assert(docs < expansion, "%s", h);
	};
}
