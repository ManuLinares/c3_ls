module lsp::stdlib_fixture;

import lsp, std::io, std::os::env;

<*
 Runs `@body` with a project that has the stdlib loaded. The stdlib is
 C3C_STDLIB_DIR (c3c's lib directory, which contains `std/`) when set, else
 the one `c3c` reports. Without either, prints why and skips `@body`.
*>
macro @with_stdlib_project(; @body(LspProject* proj))
{
	if (server::std_path.len == 0)
	{
		String dir = env::tget_var("C3C_STDLIB_DIR") ?? "";
		if (dir.len > 0)
		{
			server::std_path = dir.copy(mem);
			server::is_std_path_alloc = true;
		}
		else
		{
			server::setup_stdlib_path();
		}
	}
	defer
	{
		if (server::is_std_path_alloc)
		{
			server::std_path.free(mem);
			server::is_std_path_alloc = false;
			server::std_path = "";
		}
	};
	if (server::std_path.len == 0)
	{
		io::printn("stdlib not found (set C3C_STDLIB_DIR to c3c's lib directory); skipping");
		return;
	}

	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.process_stdlib();
	proj.update();
	@body(&proj);
}
