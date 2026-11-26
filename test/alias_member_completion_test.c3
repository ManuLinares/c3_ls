module lsp::alias_member_completion_test;
import lsp, uri;

const String SOURCE = "module demo;\nimport std::io;\n\ntypedef Text = inline char[];\ntypedef CText = inline char*;\nfn usz CText.span(self) => 1;\nfn bool char.is_x(self) => self == 'x';\nfn usz char[].count_x(self) => self.len;\nfn bool Text.is_title(self) => self.len > 0;\nalias Vec2f = float[<2>];\nfn float float[<2>].dot2(self, float[<2>] o) => self.x * o.x + self.y * o.y;\n\nfn void main()\n{\n\tText text = (Text)\"abc\";\n\tVec2f v = { 1, 2 };\n\tCText ct = (CText)\"abc\";\n\tfloat[<2>] w = { 1, 2 };\n\tusz n = text.len + ct.span();\n\tfloat d = v.x + w.x;\n}\n";

fn String members_at(uint line, uint character) @local
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri u = uri::from_file_path(mem, "/virtual/demo.c3");
	defer u.free();
	proj.workspace.process_file("/virtual/demo.c3", SOURCE);
	DString out;
	out.tinit();
	foreach (item : completion::resolve(&proj, u, { .line = line, .character = character })!!) out.appendf(" %s ", item.label);
	return out.str_view();
}

fn void inline_slice_typedef_gets_slice_members() @test
{
	String members = members_at(18, 14);
	foreach (name : (String[]){ " count_x ", " is_title ", " len ", " ptr " }) assert(members.contains(name), "%s missing from:%s", name, members);
	assert(!members.contains(" is_x "), "element method offered:%s", members);
}

fn void alias_gets_target_members() @test
{
	String alias_members = members_at(19, 13);
	test::eq(alias_members, members_at(19, 19));
	assert(alias_members.contains(" dot2 "), "%s", alias_members);
}

fn void inline_pointer_typedef_gets_no_pointee_methods() @test
{
	String members = members_at(18, 23);
	assert(members.contains(" span "), "%s", members);
	assert(!members.contains(" is_x "), "pointee method offered:%s", members);
}
