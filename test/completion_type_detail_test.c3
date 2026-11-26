module lsp::completion_type_detail_test;
import lsp, uri, std::io;

const String SOURCE = "module demo;\nconst int[4] ARR = { 1, 2, 3, 4 };\n\nstruct Mixer\n{\n\tchar[lengthof(ARR)] names;\n\tfloat[ARR.len * 2] gains;\n}\n\nfn usz Mixer.count(&self) => self.names.len;\n\nfn void main()\n{\n\tMixer m;\n\tchar[lengthof(ARR)] local_names;\n\tusz n = local_names.len + m.names.len + m.count();\n}\n";

fn String detail_at(LspPosition pos, String label) @local
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri u = uri::from_file_path(mem, "/virtual/demo.c3");
	defer u.free();
	proj.workspace.process_file("/virtual/demo.c3", SOURCE);
	foreach (it : completion::resolve(&proj, u, pos)!!)
	{
		if (it.label == label) return it.detail.tcopy();
	}
	return "<missing>";
}

fn void local_shows_declared_type() @test => test::eq(detail_at({ .line = 15, .character = 12 }, "local_names"), "char[lengthof(ARR)]");
fn void field_shows_declared_type() @test => test::eq(detail_at({ .line = 15, .character = 31 }, "names"), "char[lengthof(ARR)]");
fn void implicit_self_shows_pointer() @test => test::eq(detail_at({ .line = 9, .character = 31 }, "self"), "Mixer*");
