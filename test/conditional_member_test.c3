module lsp::conditional_member_test;
import lsp, uri;

const String GENERIC_SOURCE = "module demo;\nimport demo::box;\n\nfn void main()\n{\n\tBox{int} bi;\n\tBox{int*} bp;\n\tint q = bi.size() + bp.size();\n}\n\nmodule demo::box <Type>;\n\nconst IS_PTR = Type::kind == POINTER;\n\nstruct Box\n{\n\tType value;\n}\n\nfn int Box.size(&self) => 1;\nfn int Box.deref_only(&self) @if(IS_PTR) => 1;\nfn int Box.not_ptr(&self) @if(!IS_PTR) => 2;\n";

const String SOURCE = "module demo;\n\nstruct Point { int x; }\nfn int Point.everywhere(&self) => self.x;\n\nfn void main()\n{\n\tPoint p;\n\tint q = p.x;\n}\n\nmodule demo::apple @feat(DARWIN);\nimport demo;\n\nfn int Point.apple_only(&self) => self.x;\n";

fn String members_at(uint line, uint character, String source = SOURCE) @local
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri u = uri::from_file_path(mem, "/virtual/demo.c3");
	defer u.free();
	proj.workspace.process_file("/virtual/demo.c3", source);
	DString out;
	out.tinit();
	foreach (item : completion::resolve(&proj, u, { .line = line, .character = character })!!) out.appendf(" %s ", item.label);
	return out.str_view();
}

fn void method_of_other_platform_not_offered() @test
{
	String members = members_at(8, 11);
	assert(members.contains(" everywhere "), "%s", members);
	assert(!members.contains(" apple_only "), "offered:%s", members);
}

fn void if_condition_follows_generic_argument() @test
{
	String plain = members_at(7, 12, GENERIC_SOURCE);
	assert(plain.contains(" not_ptr ") && !plain.contains(" deref_only "), "%s", plain);
	String pointer = members_at(7, 24, GENERIC_SOURCE);
	assert(pointer.contains(" deref_only ") && !pointer.contains(" not_ptr "), "%s", pointer);
}
