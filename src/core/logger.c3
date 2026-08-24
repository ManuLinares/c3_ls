// src/core/logger.c3
module lsp::core::logger;

import lsp::server;

import std::io;
import std::time;
import std::collections::list;

File log_file;
bool has_log_file = false;
LogPriority priority_level;

fn void init()
{
	priority_level = to_category(server::log_level);

	if (server::log_path.len == 0) return;

	if (try f = file::open(server::log_path, "w"))
	{
		log_file = f;
		has_log_file = true;
		log::info("Logging to file: %s", server::log_path);
	}
	else
	{
		log::error("Failed to open log file: %s", server::log_path);
	}
}

fn void flush()
{
	if (!has_log_file) return;
	(void)log_file.flush();
}

fn void close()
{
	if (!has_log_file) return;
	(void)log_file.close();
	has_log_file = false;
}

struct LspLogger (Logger)
{
	void* dummy;
}

fn MessageType to_type(LogPriority priority) @local 
{
	switch (priority)
	{
		case CRITICAL: 
		case ERROR:
			return ERROR;
		case WARN: return WARNING;
		case INFO: return INFO;
		default: return LOG;
	}
}

fn LogPriority to_category(LogLevel level) @local 
{
	switch (level)
	{
		case DEBUG: return DEBUG;
		case INFO:  return INFO;
		case WARN:  return WARN;
		default:
			return ERROR;
	}
}

fn void LspLogger.log(&self, LogPriority priority, LogCategory category, LogTag tag, String file, String function, int line, String fmt, any[] args) @dynamic
{
	@stack_mem(256 + 64; Allocator mem)
	{
		DString str;
		str.init(mem, 256);
		str.appendf(fmt, ...args);
		TzDateTime time = datetime::now().to_local();

		$if log::FULL_LOG:
		if (has_log_file)
		{
			(void)io::fprintfn(&log_file, "[%02d:%02d:%02d:%04d] %s:%d [%s] %s", time.hour, time.min, time.sec, (time.usec / 1000), file, line, priority, str);
			(void)log_file.flush();
		}
		if (priority < priority_level) return;
		io::eprintfn("[%02d:%02d:%02d:%04d] %s:%d [%s] %s", time.hour, time.min, time.sec, (time.usec / 1000), file, line, priority, str);
		$else
		if (has_log_file)
		{
			(void)io::fprintfn(&log_file, "[%02d:%02d:%02d:%04d] [%s] %s", time.hour, time.min, time.sec, (time.usec / 1000), priority, str);
			(void)log_file.flush();
		}
		if (priority < priority_level) return;
		io::eprintfn("[%02d:%02d:%02d:%04d] [%s] %s", time.hour, time.min, time.sec, (time.usec / 1000), priority, str);
		$endif
	};
}