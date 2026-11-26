module lsp::vector_member_completion_test;
import lsp, uri;

const String SOURCE = "module demo;\nimport std::io;\n\nmacro int int[<*>].isum(self) => self[0];\nmacro float float[<*>].fmag(self) => self[0];\nfn float float[<2>].cross2(self, float[<2>] o) => self.x * o.y - self.y * o.x;\nfn float float[<3>].only3(self) => self.z;\nmacro uint uint[*].h(&self) => (*self)[0];\nfn int int[4].first4(self) => self[0];\n\nfn void main()\n{\n\tint[<4>] iv = { 1, 2, 3, 4 };\n\tfloat[<2>] f2 = { 1, 2 };\n\tfloat[<3>] f3 = { 1, 2, 3 };\n\tuint[4] ua = { 1, 2, 3, 4 };\n\tint[4] ia = { 1, 2, 3, 4 };\n\tint q = iv.x + ia.len + (int)ua.len;\n\tfloat r = f2.x + f3.x;\n}\n";

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

fn void iv_members() @test
{
	String members = members_at(17, 12);
	foreach (name : (String[]){ " isum ", " len ", " x ", " y ", " z ", " w ", " r ", " g ", " b ", " a ", " xy ", " xyz ", " xyzw ", " rgba " }) assert(members.contains(name), "%s missing from:%s", name, members);
	foreach (name : (String[]){ " fmag ", " cross2 ", " only3 ", " h ", " first4 " }) assert(!members.contains(name), "%s offered:%s", name, members);
}

fn void f2_members() @test
{
	String members = members_at(18, 14);
	foreach (name : (String[]){ " fmag ", " cross2 ", " len ", " x ", " y ", " r ", " g ", " xy " }) assert(members.contains(name), "%s missing from:%s", name, members);
	foreach (name : (String[]){ " isum ", " only3 ", " h ", " first4 ", " z ", " w ", " b ", " a ", " xyz ", " xyzw ", " rgba " }) assert(!members.contains(name), "%s offered:%s", name, members);
}

fn void f3_members() @test
{
	String members = members_at(18, 21);
	foreach (name : (String[]){ " fmag ", " only3 ", " len ", " x ", " y ", " z ", " r ", " g ", " b ", " xy ", " xyz " }) assert(members.contains(name), "%s missing from:%s", name, members);
	foreach (name : (String[]){ " isum ", " cross2 ", " h ", " first4 ", " w ", " a ", " xyzw ", " rgba " }) assert(!members.contains(name), "%s offered:%s", name, members);
}

fn void ua_members() @test
{
	String members = members_at(17, 33);
	foreach (name : (String[]){ " h ", " len " }) assert(members.contains(name), "%s missing from:%s", name, members);
	foreach (name : (String[]){ " isum ", " fmag ", " cross2 ", " only3 ", " first4 ", " x ", " y ", " z ", " w ", " r ", " g ", " b ", " a ", " xy ", " xyz ", " xyzw ", " rgba " }) assert(!members.contains(name), "%s offered:%s", name, members);
}

fn void ia_members() @test
{
	String members = members_at(17, 19);
	foreach (name : (String[]){ " first4 ", " len " }) assert(members.contains(name), "%s missing from:%s", name, members);
	foreach (name : (String[]){ " isum ", " fmag ", " cross2 ", " only3 ", " h ", " x ", " y ", " z ", " w ", " r ", " g ", " b ", " a ", " xy ", " xyz ", " xyzw ", " rgba " }) assert(!members.contains(name), "%s offered:%s", name, members);
}
