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
 Invokes clang on the header with `mode_args` and captures both stdout and stderr.
 @param allocator : "Allocator used for output strings."
 @param options   : "Bindgen configuration options."
 @param mode_args : "Flags selecting clang's output, e.g. an AST dump or preprocessed macros."
 @return          "Clang output containing stdout and stderr, or a fault on failure."
*>
fn ClangOutput? run_clang_raw(Allocator allocator, BindgenOptions options, String[] mode_args)
{
	String clang_bin = options.clang_path.len > 0 ? options.clang_path : "clang";

	List{String} cmd;
	cmd.tinit();

	cmd.push(clang_bin);
	cmd.push("-Wno-everything");
	cmd.push(CLANG_ERROR_LIMIT);
	foreach (arg : mode_args) cmd.push(arg);

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

	Process? proc = process::spawn(cmd.array_view(), options: ASYNC_OUTPUT);
	if (catch proc)
	{
		return CLANG_NOT_FOUND~;
	}
	defer (void)proc.destroy();

	DString stdout_buf;
	stdout_buf.init(allocator);
	DString stderr_buf;
	stderr_buf.init(allocator);
	while (true)
	{
		bool exited = !(proc.is_running() ?? false);
		bool got_output = drain_pipe(&proc, &stdout_buf, true) | drain_pipe(&proc, &stderr_buf, false);
		if (exited) break;
		if (!got_output) thread::sleep_ms(1);
	}

	return {
		.stdout_str = stdout_buf.str_view(),
		.stderr_str = stderr_buf.str_view()
	};
}

<*
 Appends whatever a non-blocking stdout or stderr pipe currently holds. Reading both pipes in turn
 keeps a full stderr pipe from blocking the child while stdout is still being read.
 @return "Whether anything was read."
*>
fn bool drain_pipe(Process* proc, DString* out, bool is_stdout) @local
{
	char[CLANG_READ_CHUNK_SIZE] chunk;
	bool got_output;
	while (try n = (is_stdout ? proc.read_stdout(&chunk, chunk.len) : proc.read_stderr(&chunk, chunk.len)))
	{
		if (n <= 0) break;
		out.append((String)chunk[:n]);
		got_output = true;
	}
	return got_output;
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
		ClangOutput? out = run_clang_raw(allocator, *options, { "-Xclang", "-ast-dump=json", "-fsyntax-only" });
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
<*
 Invokes clang's preprocessor keeping #define directives in place, with line markers naming their files.
*>
fn String? run_clang_macro_dump(Allocator allocator, BindgenOptions options)
{
	ClangOutput out = run_clang_raw(allocator, options, { "-E", "-dD" })!;
	if (out.stdout_str.len == 0)
	{
		if (out.stderr_str.len > 0)
		{
			log::error("Clang stderr: %s", out.stderr_str);
		}
		return INVALID_CLANG_OUTPUT~;
	}
	return out.stdout_str;
}

<*
 C source that includes the header once, followed by each probe section.
*>
fn String build_probe(String header_path, String[] sections)
{
	DString out;
	out.tinit();
	out.appendf("#include \"%s\"\n", header_path);
	foreach (section : sections) out.append(section);
	return out.str_view();
}

<*
 Runs clang on a probe source that includes the header followed by `sections`, returning the AST JSON.
 Invalid probes are expected, so the error limit is lifted.
*>
fn String? run_clang_probe(Allocator allocator, BindgenOptions options, String[] sections)
{
	Path probe = path::temp_directory(tmem)!.tappend(string::tformat("c3_bindgen_probe_%d.c", (int)datetime::now().sec))!;
	String header = (String)options.header_path.to_absolute_path(tmem)!;
	file::save(probe, build_probe(header, sections))!;
	defer (void)file::delete(probe);

	options.header_path = (String)probe;
	ClangOutput out = run_clang_raw(allocator, options, { "-Xclang", "-ast-dump=json", "-fsyntax-only", "-ferror-limit=0" })!;
	if (!out.stdout_str.starts_with("{"))
	{
		if (out.stderr_str.len > 0) log::error("Clang stderr: %s", out.stderr_str);
		return INVALID_CLANG_OUTPUT~;
	}
	return out.stdout_str;
}
