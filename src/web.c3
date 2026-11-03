module lsp::web @feat(EMSCRIPTEN);
import analyzer::core, std;

DString result_buf;

struct WebDiag
{
	int line;
	int column;
	int end_line;
	int end_column;
	String level;
	String message;
}

List{WebDiag} current_diags;

fn void on_web_diagnostic(SourceFile* file, Range range, DiagnosticLevel level, String message)
{
	String lvl = "error";
	switch (level)
	{
		case NOTE: lvl = "note";
		case INFO: lvl = "info";
		case WARN: lvl = "warning";
		case ERROR: lvl = "error";
	}

	current_diags.push({
		.line = range.start.line,
		.column = range.start.column,
		.end_line = range.end.line,
		.end_column = range.end.column,
		.level = lvl,
		.message = message.copy(mem)
	});
}

fn void ser_json_string(DString* out, String s) @local
{
	out.append_char('"');
	foreach (char c : s)
	{
		switch (c)
		{
			case '"': out.append("\\\"");
			case '\\': out.append("\\\\");
			case '\n': out.append("\\n");
			case '\r': out.append("\\r");
			case '\t': out.append("\\t");
			default: out.append_char(c);
		}
	}
	out.append_char('"');
}

fn int main()
{
	result_buf.init(mem);
	return 0;
}

fn ZString parse_c3_ast(ZString source_cstr) @export("parse_c3_ast")
{
	result_buf.clear();
	if (!source_cstr) return "{\"errors\":[],\"ast\":[]}";

	current_diags.init(mem);
	defer
	{
		foreach (d : current_diags)
		{
			d.message.free(mem);
		}
		current_diags.free();
	};

	diagnostics::callback = &on_web_diagnostic;
	defer diagnostics::callback = null;

	@pool()
	{
		AnalyzerContext* ctx = context::create(mem);
		defer context::free(ctx);

		context::process(ctx, source_cstr.str_view(), "playground.c3");

		result_buf.append("{\"errors\":[");
		for (sz i = 0; i < current_diags.len(); i++)
		{
			WebDiag d = current_diags.get(i);
			if (i > 0) result_buf.append_char(',');
			result_buf.appendf("{\"line\":%d,\"column\":%d,\"endLine\":%d,\"endColumn\":%d,\"level\":",
				d.line, d.column, d.end_line, d.end_column);
			result_buf.appendf("\"%s\",\"message\":", d.level);
			ser_json_string(&result_buf, d.message);
			result_buf.append_char('}');
		}
		result_buf.append("],\"ast\":[");

		if (try sf = ctx.files.get("playground.c3"))
		{
			for (sz i = 0; i < sf.ast.statements.len(); i++)
			{
				Node* stmt = sf.ast.statements.get(i);
				if (!stmt) continue;
				if (i > 0) result_buf.append_char(',');
				result_buf.append(stmt.serialize(tmem, 2));
			}
		}
		result_buf.append("]}");
	};

	return result_buf.zstr_view();
}