module lsp;

import lsp::server;
import lsp::bindgen;

import std;
import std::os::argparse;

const sz MAX_CLI_INCLUDES = 32;
const sz MAX_CLI_DEFINES = 32;

struct CliArgs
{
	String stdlib_path;
	String compiler_path;
	String log_path;
	String cache_path;
	LogLevel log_level;
	uint diagnostics_delay;
	bool send_crash_reports;
	bool stdio;
	bool version;
	bool help;

	// Bindgen options
	String bindgen;
	String bindgen_out;
	String bindgen_mod;
	String bindgen_type_prefix;
	String bindgen_strip_prefix;
	String clang_path;
	String[MAX_CLI_INCLUDES] includes;
	String[MAX_CLI_DEFINES] defines;
}

fn int main(String[] args)
{
	CliArgs cli = {
		.log_level = ERROR
	};

	sz? result = argparse::@parse(args,
		"h*", "help*", "Show help manual",                                           &cli.help,
		"",  "stdlib-path", "Path to C3 standard library",                           &cli.stdlib_path,
		"",  "compiler-path", "Path to c3c executable",                              &cli.compiler_path,
		"",  "log-path", "Path to log file",                                         &cli.log_path,
		"",  "cache-path", "Override where cache files are stored",                  &cli.cache_path,
		"",  "log-level", "Minimum log level (debug|info|warn|error)",               &cli.log_level,
		"",  "diagnostics-delay", "Delay in ms before calculating diagnostics",      &cli.diagnostics_delay,
		"",  "send-crash-reports", "Send crash reports",                             &cli.send_crash_reports,
		"",  "stdio", "Run server via standard I/O (default)",                       &cli.stdio,
		"v", "version", "Print version",                                             &cli.version,
		"",  "bindgen", "Generate C3 bindings from <header.h>",                      &cli.bindgen,
		"o", "output", "Output file path (.c3 or .c3i)",                             &cli.bindgen_out,
		"m", "module", "Module name for generated bindings (default: header name)",  &cli.bindgen_mod,
		"",  "type-prefix", "Type prefix for generated types (e.g. RL)",             &cli.bindgen_type_prefix,
		"",  "strip-prefix", "Function prefix to strip (default: <module>_)",        &cli.bindgen_strip_prefix,
		"",  "clang-path", "Path to clang executable",                               &cli.clang_path,
		"I", "include", "Include directory for clang (can be repeated)",             &cli.includes,
		"D", "define", "Macro definition for clang (can be repeated)",               &cli.defines
	);

	if (catch err = result)
	{
		if (err == argparse::HELP_REQUESTED)
		{
			return 0;
		}
		io::eprintfn("Command-line error: %s (unrecognized option: '%s', args: %s)", err, argparse::last_opt, args);
		return 1;
	}

	if (cli.version)
	{
		io::printfn("c3_ls %s", env::PROJECT_VERSION);
		return 0;
	}

	if (cli.bindgen.len > 0)
	{
		List{String} inc_list;
		inc_list.tinit();
		foreach (s : cli.includes)
		{
			if (s.len > 0)
			{
				inc_list.push(s);
			}
		}

		List{String} def_list;
		def_list.tinit();
		foreach (s : cli.defines)
		{
			if (s.len > 0)
			{
				def_list.push(s);
			}
		}

		String mod_name = cli.bindgen_mod;
		if (mod_name.len == 0)
		{
			String clean_target = cli.bindgen.trim_right("/\\");
			sz last_slash = 0;
			if (try idx = clean_target.rindex_of_char('/'))
			{
				last_slash = idx + 1;
			}
			else if (try idx = clean_target.rindex_of_char('\\'))
			{
				last_slash = idx + 1;
			}

			String file_base = clean_target[last_slash..];
			if (try dot_idx = file_base.index_of_char('.'))
			{
				file_base = file_base[:dot_idx];
			}
			mod_name = file_base;
		}

		mod_name = bindgen::sanitize_module_name(tmem, mod_name);

		bindgen::BindgenOptions opts = {
			.header_path = cli.bindgen,
			.output_path = cli.bindgen_out,
			.module_name = mod_name,
			.type_prefix = cli.bindgen_type_prefix,
			.strip_func_prefix = cli.bindgen_strip_prefix,
			.clang_path = cli.clang_path,
			.include_dirs = inc_list.array_view(),
			.defines = def_list.array_view()
		};

		return bindgen::run_bindgen(opts, is_cli: true);
	}

	server::start(cli);
	return 0;
}