module lsp::bindgen;

import std;

const sz CLANG_READ_CHUNK_SIZE = 65536;

faultdef
CLANG_NOT_FOUND,
CLANG_FAILED,
INVALID_CLANG_OUTPUT;

<*
 Invokes clang to produce a JSON AST dump of the target C header.
 @param allocator : "Allocator used for the returned JSON string."
 @param options   : "Bindgen configuration options."
 @return "Full JSON AST string, or a fault on failure."
*>
fn String? run_clang_ast_dump(Allocator allocator, BindgenOptions options)
{
	String clang_bin = options.clang_path.len > 0 ? options.clang_path : "clang";

	List{String} cmd;
	cmd.tinit();

	cmd.push(clang_bin);
	cmd.push("-Xclang");
	cmd.push("-ast-dump=json");
	cmd.push("-fsyntax-only");
	cmd.push("-Wno-everything");

	if (options.target.len > 0)
	{
		cmd.push("-target");
		cmd.push(options.target);
	}

	foreach (inc : options.include_dirs)
	{
		if (inc.len > 0)
		{
			cmd.push(string::tformat("-I%s", inc));
		}
	}

	foreach (def : options.defines)
	{
		if (def.len > 0)
		{
			cmd.push(string::tformat("-D%s", def));
		}
	}

	cmd.push(options.header_path);

	Process? proc = process::spawn(cmd.array_view());
	if (catch proc)
	{
		return CLANG_NOT_FOUND~;
	}

	DString stdout_buf;
	stdout_buf.init(allocator);

	char[CLANG_READ_CHUNK_SIZE] chunk;
	while (true)
	{
		long? bytes_read = proc.read_stdout(&chunk, CLANG_READ_CHUNK_SIZE);
		if (catch bytes_read)
		{
			break;
		}

		long n = bytes_read;
		if (n <= 0)
		{
			break;
		}

		stdout_buf.append((String)chunk[:n]);
	}

	if (catch proc.join())
	{
		stdout_buf.free();
		return CLANG_FAILED~;
	}

	String result = stdout_buf.str_view().trim();
	if (result.len == 0 || !result.starts_with("{"))
	{
		char[4096] err_buf;
		if (try long err_len = proc.read_stderr(&err_buf, 4096))
		{
			if (err_len > 0)
			{
				log::error("Clang stderr: %s", (String)err_buf[:(sz)err_len]);
			}
		}

		stdout_buf.free();
		return INVALID_CLANG_OUTPUT~;
	}

	return result;
}