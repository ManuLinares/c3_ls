module source_buffer_tests;

import analyzer::core;
import analyzer::lexer;

fn void tokens_point_into_source_file_content() @test
{
	AnalyzerContext* context = context::create(mem);
	defer context::free(context);
	String buffer = "module app;\nfn int add(int a, int b) => a + b;\n".copy(mem);
	context::process(context, buffer, "app.c3");
	buffer.free(mem);

	SourceFile* sf = context.files.get("app.c3")!!;
	assert(sf.lexer.buffer.ptr == sf.content.ptr);
	foreach (tok : sf.lexer.tokens)
	{
		if (!tok.kind.is_identifier()) continue;
		assert(tok.value.ptr >= sf.content.ptr && tok.value.ptr + tok.value.len <= sf.content.ptr + sf.content.len, "%s", tok.value);
	}
	assert(sf.lexer.tokens[1].value == "app");
}
