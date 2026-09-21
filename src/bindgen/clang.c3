module lsp::bindgen;

import std;

const sz CLANG_READ_CHUNK_SIZE = 65536;
const String CLANG_ERROR_LIMIT = "-ferror-limit=50";

faultdef
CLANG_NOT_FOUND,
CLANG_FAILED,
INVALID_CLANG_OUTPUT;

struct ClangOutput
{
	String stdout_str;
	String stderr_str;
}

<*
 Invokes clang to produce a JSON AST dump and captures both stdout and stderr.
 @param allocator : "Allocator used for output strings."
 @param options   : "Bindgen configuration options."
 @return          "Clang output containing stdout and stderr, or a fault on failure."
*>
fn ClangOutput? run_clang_ast_dump_raw(Allocator allocator, BindgenOptions options)
{
	String clang_bin = options.clang_path.len > 0 ? options.clang_path : "clang";

	List{String} cmd;
	cmd.tinit();

	cmd.push(clang_bin);
	cmd.push("-Xclang");
	cmd.push("-ast-dump=json");
	cmd.push("-fsyntax-only");
	cmd.push("-Wno-everything");
	cmd.push(CLANG_ERROR_LIMIT);

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

	DString stderr_buf;
	stderr_buf.init(allocator);

	char[4096] err_chunk;
	while (true)
	{
		long? bytes_read = proc.read_stderr(&err_chunk, 4096);
		if (catch bytes_read)
		{
			break;
		}

		long n = bytes_read;
		if (n <= 0)
		{
			break;
		}

		stderr_buf.append((String)err_chunk[:n]);
	}

	(void)proc.join();

	return {
		.stdout_str = stdout_buf.str_view().copy(allocator),
		.stderr_str = stderr_buf.str_view().copy(allocator)
	};
}

<*
 Extracts the first missing header file path from Clang's stderr diagnostics.
 Matches: fatal error: '<header.h>' file not found
*>
fn String extract_missing_header_from_stderr(String stderr_str)
{
	const String PATTERN = "fatal error: '";
	const String SUFFIX = "' file not found";

	if (try idx = stderr_str.index_of(PATTERN))
	{
		String rest = stderr_str[idx + PATTERN.len..];
		if (try end_idx = rest.index_of(SUFFIX))
		{
			return rest[:end_idx].trim();
		}
	}

	return "";
}

<*
 Invokes clang with diagnostic self-healing:
 If a header file is missing, searches system and sibling include paths,
 adds the directory to include_dirs, and retries automatically.
*>
fn String? run_clang_ast_dump(Allocator allocator, BindgenOptions* options)
{
	const int MAX_SELF_HEAL_ATTEMPTS = 6;

	for (int attempt = 0; attempt < MAX_SELF_HEAL_ATTEMPTS; attempt++)
	{
		ClangOutput? out = run_clang_ast_dump_raw(allocator, *options);
		if (catch err = out)
		{
			return err~;
		}

		String stdout_str = out.stdout_str.trim();
		String stderr_str = out.stderr_str;

		String missing = extract_missing_header_from_stderr(stderr_str);
		if (missing.len > 0)
		{
			sz prev_count = options.include_dirs.len;
			String? found_dir = find_missing_header_directory(*options, missing);
			if (try dir = found_dir)
			{
				add_unique_include(options, dir.copy(allocator));
				if (options.include_dirs.len > prev_count)
				{
					continue;
				}
			}
		}

		if (stdout_str.len == 0 || !stdout_str.starts_with("{"))
		{
			if (stderr_str.len > 0)
			{
				log::error("Clang stderr: %s", stderr_str);
			}
			return INVALID_CLANG_OUTPUT~;
		}

		return stdout_str;
	}

	return INVALID_CLANG_OUTPUT~;
}