module lsp::slice_method_completion_test;
import lsp, uri;

const String SOURCE = "module demo;\nimport std::io;\n\nfn void char[].only_for_slices(self) => io::printn(\"slice method\");\nfn bool char.is_vowel(self) => self == 'a';\n\nfn void main()\n{\n\tchar[4] plain;\n\tchar[] slice = &plain;\n\tchar ch = 'a';\n\tslice.only_for_slices();\n\tbool v = ch.is_vowel();\n\tusz n = plain.len;\n}\n";

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
	foreach (item : completion::resolve(&proj, u, { .line = line, .character = character })!!) out.appendf("%s ", item.label);
	return out.str_view().trim();
}

fn void slice_gets_slice_methods() @test => test::eq(members_at(11, 7), "len ptr only_for_slices");
fn void element_type_gets_no_slice_methods() @test => test::eq(members_at(12, 13), "is_vowel");
fn void array_gets_no_slice_methods() @test => test::eq(members_at(13, 15), "len");
