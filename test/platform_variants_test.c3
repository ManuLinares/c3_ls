module lsp::platform_variants_test;

import lsp, lsp::analysis::definition, lsp::analysis::completion, lsp::analysis::hover, uri, analyzer::core::arch;

const String POSIX = "module plat @feat(POSIX);\nstruct Mutex { int posix_field; }\nfn void Mutex.lock(&self) {}\nfn void use_posix(Mutex* mx) { mx.posix_field = 1; }\n";
const String WIN = "module plat @feat(WIN32);\nstruct Mutex { int win_field; }\nfn void Mutex.lock(&self) {}\nfn void use_win(Mutex* mx) { mx.win_field = 1; }\n";
const String APP = "module app;\nimport plat;\nfn bool alive() @feat(!WIN32) => true;\nfn bool alive() @feat(WIN32) => false;\nfn void main()\n{\n\tplat::Mutex m;\n\tm.lock();\n\t(void)alive();\n}\n";

<*
 POSIX is processed before WIN32, so a lookup that takes the last processed variant picks WIN32.
*>
macro LspProject* open_platforms()
{
	LspProject* proj = mem::new(LspProject);
	proj.init(mem);
	proj.workspace.process_file("/virtual/posix.c3", POSIX);
	proj.workspace.process_file("/virtual/win.c3", WIN);
	proj.workspace.process_file("/virtual/app.c3", APP);
	return proj;
}

macro void close(LspProject* proj)
{
	proj.free();
	mem::free(proj);
}

macro sz definitions_at(LspProject* proj, String file, uint line, uint character)
{
	return definition::goto_definition(proj, uri::from_file_path(tmem, file), { line, character })!!.len;
}

macro bool completes(LspProject* proj, String file, uint line, uint character, String label)
{
	foreach (item : completion::resolve(proj, uri::from_file_path(tmem, file), { line, character })!!) if (item.label == label) return true;
	return false;
}

fn void definition_returns_every_platform_variant() @test
{
	LspProject* proj = open_platforms();
	defer close(proj);
	assert(definitions_at(proj, "/virtual/app.c3", 6, 9) == 2, "type");
	assert(definitions_at(proj, "/virtual/app.c3", 7, 4) == 2, "method");
	assert(definitions_at(proj, "/virtual/app.c3", 8, 9) == 2, "function");
}

fn void neutral_code_sees_the_target_variant() @test
{
	LspProject* proj = open_platforms();
	defer close(proj);
	bool win = env::WIN32;
	assert(completes(proj, "/virtual/app.c3", 7, 3, win ? "win_field" : "posix_field"), "target field missing");
	assert(!completes(proj, "/virtual/app.c3", 7, 3, win ? "posix_field" : "win_field"), "other platform's field offered");
}

fn void platform_code_sees_its_own_variant() @test
{
	LspProject* proj = open_platforms();
	defer close(proj);
	assert(completes(proj, "/virtual/posix.c3", 3, 34, "posix_field"));
	assert(!completes(proj, "/virtual/posix.c3", 3, 34, "win_field"));
	assert(completes(proj, "/virtual/win.c3", 3, 32, "win_field"));
	assert(!completes(proj, "/virtual/win.c3", 3, 32, "posix_field"));
}

macro String hover_in_project(String[] features, String path, String source, uint line, uint character)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	String[] own = alloc::alloc_array(mem, String, features.len);
	foreach (i, f : features) own[i] = f.copy(mem);
	proj.config.features = own;
	Uri u = uri::from_file_path(tmem, path);
	proj.open_file({ .uri = (DocumentUri)u.to_raw_string(tmem), .language_id = "c3", .version = 1, .text = source });
	proj.update();
	return hover::hover(&proj, u, { line, character })!!.tcopy();
}

const String SPEED = "module app;\nfn int speed() @feat(FAST) => 1;\nfn int speed() @feat(!FAST) => 2;\nfn int main() => speed();\n";

fn void project_features_pick_the_variant() @test
{
	String h = hover_in_project({ "FAST" }, "/virtual/fast.c3", SPEED, 3, 19);
	assert(h.contains("@feat(FAST)") && !h.contains("!FAST"), "with FAST: %s", h);
	h = hover_in_project({}, "/virtual/fast.c3", SPEED, 3, 19);
	assert(h.contains("@feat(!FAST)"), "without FAST: %s", h);
}

fn void test_files_have_testing() @test
{
	String src = "module app;\nfn int mode() @feat(TESTING) => 1;\nfn int mode() @feat(!TESTING) => 2;\nfn int main() => mode();\n";
	assert(hover_in_project({}, "/virtual/test/mode_test.c3", src, 3, 18).contains("@feat(TESTING)"));
	assert(hover_in_project({}, "/virtual/src/mode.c3", src, 3, 18).contains("@feat(!TESTING)"));
}

const String SRC_TYPES = "module plat @feat(MACOS, LINUX, WIN32);\nstruct Src @feat(MACOS) { int view; }\nstruct Src @feat(LINUX) { int xwin; }\nstruct Src @feat(WIN32) { int hwnd; }\n";

fn void platform_code_sees_its_platform_variant() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/types.c3", SRC_TYPES);
	proj.workspace.process_file("/virtual/mac.c3", "module plat::mac @feat(MACOS);\nimport plat;\nfn void use_mac(plat::Src* s) { s.view = 1; }\n");
	proj.workspace.process_file("/virtual/win.c3", "module plat::win @feat(WIN32);\nimport plat;\nfn void use_win(plat::Src* s) { s.hwnd = 1; }\n");
	assert(completes(&proj, "/virtual/mac.c3", 2, 34, "view"), "macOS code");
	assert(!completes(&proj, "/virtual/mac.c3", 2, 34, "xwin"), "macOS code sees Linux");
	assert(completes(&proj, "/virtual/win.c3", 2, 34, "hwnd"), "Windows code");
}

fn void platform_code_in_a_file_ending_with_other_code() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/all.c3", "module plat @feat(MACOS, LINUX, WIN32);\nstruct Src @feat(MACOS) { int view; }\nstruct Src @feat(LINUX) { int xwin; }\nstruct Src @feat(WIN32) { int hwnd; }\nmodule plat::mac @feat(MACOS);\nimport plat;\nfn void use_mac(plat::Src* s) { s.view = 1; }\nmodule other;\nfn void nothing() {}\n");
	assert(completes(&proj, "/virtual/all.c3", 6, 34, "view"));
	assert(!completes(&proj, "/virtual/all.c3", 6, 34, "xwin"));
}

fn void hover_on_a_member_through_a_platform_variant() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/all.c3", "module plat @feat(MACOS, LINUX, WIN32);\nstruct Src @feat(MACOS) { int view; }\nstruct Src @feat(LINUX) { int xwin; }\nstruct Src @feat(WIN32) { int hwnd; }\nstruct Win { Src src; }\nmodule plat::mac @feat(MACOS);\nimport plat;\nfn void use_mac(plat::Win* w) { w.src.view = 1; }\nmodule other;\nfn void nothing() {}\n");
	String h = hover::hover(&proj, uri::from_file_path(tmem, "/virtual/all.c3"), { 7, 41 })!!;
	assert(h.starts_with("```c3\nint view\n```"), "hover: %s", h);
}

fn void platform_code_assumes_its_custom_features() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/wl.c3", "module plat @feat(BSD, LINUX);\nstruct Src @feat(LINUX) { int xwin; }\nstruct Src @feat(BSD)\n{\n\tint fd;\n\tstruct @feat(WAYLAND)\n\t{\n\t\tint surface;\n\t}\n}\nmodule plat::bsd @feat(BSD);\nimport plat;\nfn void use_wl(plat::Src* s) @feat(WAYLAND) { s.surface = 1; }\nmodule other;\nfn void nothing() {}\n");
	String h = hover::hover(&proj, uri::from_file_path(tmem, "/virtual/wl.c3"), { 12, 49 })!!;
	assert(h.starts_with("```c3\nint surface\n```"), "hover: %s", h);
}

fn void feat_branches_narrow_the_platform() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/br.c3", "module plat @feat(MACOS, LINUX);\nstruct Src @feat(MACOS) { int view; }\nstruct Src @feat(LINUX)\n{\n\tint xwin;\n\tstruct @feat(WAYLAND)\n\t{\n\t\tint surface;\n\t}\n}\nfn void both(Src* s) @feat(WAYLAND, MACOS)\n{\n\t$switch:\n\t\t$case $feat(MACOS):\n\t\t\ts.view = 1;\n\t\t$case $feat(WAYLAND):\n\t\t\ts.surface = 1;\n\t$endswitch\n}\nmodule other;\nfn void nothing() {}\n");
	Uri u = uri::from_file_path(tmem, "/virtual/br.c3");
	String h = hover::hover(&proj, u, { 14, 6 })!!;
	assert(h.starts_with("```c3\nint view\n```"), "macOS branch: %s", h);
	h = hover::hover(&proj, u, { 16, 6 })!!;
	assert(h.starts_with("```c3\nint surface\n```"), "Wayland branch: %s", h);
}

fn void platform_code_sees_every_variant_it_can_be_built_with() @test
{
	// AARCH64 code is built on Linux and on macOS, which declare different `Regs`.
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	String source = "module repro;\n\nstruct Regs @feat(LINUX) { int linux_reg; }\nstruct Regs @feat(MACOS) { int mac_reg; }\nstruct Regs @feat(WIN32) { int win_reg; }\n\nfn void read_regs() @feat(AARCH64 & POSIX)\n{\n\tRegs r;\n\tr.linux_reg = 1;\n}\n";
	proj.workspace.process_file("/virtual/arm.c3", source);
	Uri u = uri::from_file_path(tmem, "/virtual/arm.c3");
	bool arm = env::AARCH64 && env::POSIX;
	if (!arm)
	{
		assert(completes(&proj, "/virtual/arm.c3", 9, 3, "linux_reg"), "Linux variant missing");
		assert(completes(&proj, "/virtual/arm.c3", 9, 3, "mac_reg"), "macOS variant missing");
		assert(!completes(&proj, "/virtual/arm.c3", 9, 3, "win_reg"), "Windows is never POSIX");
		assert(hover::hover(&proj, u, { 9, 4 })!!.starts_with("```c3\nint linux_reg\n```"), "hover linux_reg");
	}
}

fn void target_features_match_c3c() @test
{
	String[] linux_arm = arch::features(tmem, { .os = LINUX, .arch = AARCH64 });
	foreach (f : (String[*]){ "LIBC", "NATIVE_I128", "NATIVE_F16", "POSIX", "LINUX", "AARCH64", "ARCH_64_BIT", "BACKTRACE" }) assert(array::contains(linux_arm, f), "linux-aarch64 lacks %s", f);
	String[] wasm = arch::features(tmem, { .os = UNKNOWN, .arch = WASM32 });
	assert(array::contains(wasm, "NO_LIBC") && array::contains(wasm, "FREESTANDING_WASM") && !array::contains(wasm, "LIBC"), "wasm32");
	assert(!array::contains(arch::features(tmem, { .os = LINUX, .arch = X86_64 }), "NATIVE_I128"), "linux-x64 has no native int128");
}
