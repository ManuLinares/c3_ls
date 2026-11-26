module lsp::inline_member_test;
import lsp, uri;

const String SOURCE = "module demo;\n\nstruct Point { int x; }\nfn int Point.get(&self) => self.x;\nstruct ByValue { inline Point pt; }\nstruct ByArray { inline Point[2] pts; }\nstruct ByPointer { inline Point* pp; }\n\nfn void main()\n{\n\tByValue bv;\n\tByArray ba;\n\tByPointer bp;\n\tint q = bv.x + ba.pts[0].x + bp.pp.x;\n}\n";

fn String members_at(uint character) @local
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri u = uri::from_file_path(mem, "/virtual/demo.c3");
	defer u.free();
	proj.workspace.process_file("/virtual/demo.c3", SOURCE);
	DString out;
	out.tinit();
	foreach (item : completion::resolve(&proj, u, { .line = 13, .character = character })!!) out.appendf(" %s ", item.label);
	return out.str_view();
}

fn void inline_struct_member_exposes_fields() @test
{
	String members = members_at(12);
	assert(members.contains(" x ") && members.contains(" get "), "%s", members);
}

fn void inline_array_member_exposes_no_fields() @test
{
	String members = members_at(19);
	assert(!members.contains(" x ") && !members.contains(" get "), "%s", members);
}

fn void inline_pointer_member_exposes_no_fields() @test
{
	String members = members_at(33);
	assert(!members.contains(" x ") && !members.contains(" get "), "%s", members);
}
