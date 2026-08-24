// src/main.c3
module lsp;
import lsp::server;

import std::collections::maybe;
import std::os::argparse;
import std::io;

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
}

fn int main(String[] args)
{
	CliArgs cli = {
		.log_level = ERROR
	};

	sz? result = argparse::@parse(args,
		"",  "stdlib-path", "stdlib path",                              &cli.stdlib_path,
		"",  "compiler-path", "Path to c3c executable",                 &cli.compiler_path,
		"",  "log-path", "Path to log file",                            &cli.log_path,
		"",  "cache-path", "Override where the cache files are stored",   &cli.cache_path,
		"",  "log-level", "On which level to log to stderr",            &cli.log_level,                     
		"",  "diagnostics-delay", "Delay before calculating diagnostics", &cli.diagnostics_delay,
		"",  "send-crash-reports", "Send crash reports",                &cli.send_crash_reports,
		"",  "stdio", "Run server via standard I/O (default)",          &cli.stdio,
		"v", "version", "Print version",                                &cli.version,
	);

	if (catch err = result)
	{
		if (err == argparse::HELP_REQUESTED) return 0;
		io::eprintfn("Command-line error: %s (unrecognized option: '%s', args: %s)", err, argparse::last_opt, args);
		return 1;
	}

	if (cli.version)
	{
		io::printfn("c3_ls %s", env::PROJECT_VERSION);
		return 0;
	}

	server::start(cli);
	return 0;
}