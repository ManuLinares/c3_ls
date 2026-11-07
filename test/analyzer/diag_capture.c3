module diag_capture;

import analyzer::core;
import std::collections::list;
import std::io;

struct Diag (Printable)
{
	Range range;
	String message;
}

fn sz? Diag.to_format(&self, Formatter* f) @dynamic
{
	return f.printf("%d:%d %s", self.range.start.line, self.range.start.column, self.message);
}

List{Diag} captured @local;

fn void record(SourceFile* file, Range range, DiagnosticLevel level, String message) @local
{
	// Diagnostics are reported inside @pool scopes, so record on the heap.
	if (level == ERROR) captured.push({ .range = range, .message = message.copy(mem) });
}

<* Errors reported while processing `src` as a standalone file. *>
fn Diag[] errors_for(String src)
{
	captured.init(mem);
	defer captured.free();
	diagnostics::callback = &record;
	defer diagnostics::callback = null;
	AnalyzerContext* context = context::create(tmem);
	context::process(context, src, "capture.c3");

	Diag[] out = mem::temp_array(Diag, captured.len());
	foreach (i, d : captured)
	{
		out[i] = { .range = d.range, .message = d.message.copy(tmem) };
		d.message.free(mem);
	}
	return out;
}
