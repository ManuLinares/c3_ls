module lsp::web @feat(EMSCRIPTEN);
import analyzer::core::ast::serialize, analyzer::core::context;
import std::io;

DString result_buf;

fn int main()
{
	result_buf.init(mem);
	return 0;
}

fn ZString parse_c3_ast(ZString source_cstr) @export("parse_c3_ast")
{
	result_buf.clear();
	if (!source_cstr) return "[]";

	@pool()
	{
		AnalyzerContext* ctx = context::create(tmem);
		// defer context::free(ctx);

		context::process(ctx, source_cstr.str_view(), "playground.c3");

		if (try sf = ctx.files.get("playground.c3"))
		{
			if (sf.ast.statements.len() == 0) return "[]";
			result_buf.append("[\n");
			for (sz i = 0; i < sf.ast.statements.len(); i++)
			{
				Node* stmt = sf.ast.statements.get(i);
				if (!stmt) continue;
				if (i > 0) result_buf.append(",\n");
				result_buf.append(stmt.serialize(tmem, 2));
			}
			result_buf.append("\n]");
		}
		else
		{
			result_buf.append("[]");
		}
	};

	return result_buf.zstr_view();
}