module analyzer::core::context;

import analyzer::core::diagnostics;
import analyzer::core::source_file;
import analyzer::core::arch;
import analyzer::core::os;
import analyzer::core::mod;
import analyzer::core::ast;

import analyzer::lexer;
import analyzer::parser;
import analyzer::sema;
import analyzer::sema::lookup;
import analyzer::sema::registry;

import std::io;
<*
 If target.os or target.arch is `UNKNOWN` it will be inferred
*>
fn AnalyzerContext* create(Allocator alloc, Target target = {})
{
	AnalyzerContext* ctx = alloc::new(alloc, AnalyzerContext);

	ctx.allocator = alloc;
	ctx.files.init(alloc);
	ctx.modules.init(alloc);
	ctx.target = target;

	if (target.arch == UNKNOWN)
	{
		target.arch = arch::current();
	}

	if (target.os == UNKNOWN)
	{
		target.os = os::current();
	}

	ctx.target.layout = arch::get_platform_layout(target.os, target.arch);

	ctx.lookup = lookup::create(ctx, alloc);
	ctx.registry = registry::create(alloc);

	return ctx;
}<*
 @require ctx != null
*>
fn void free(AnalyzerContext* ctx)
{
	foreach (sf : ctx.files.values(tmem))
	{
		source_file::free(ctx, sf);
	}
	ctx.files.free();

	foreach (m : ctx.modules.values(tmem))
	{
		mod::free(ctx, m);
	}
	ctx.modules.free();

	if (ctx.lookup) lookup::free(ctx, ctx.lookup);
	if (ctx.registry) registry::free(ctx, ctx.registry);

	alloc::free(ctx.allocator, ctx);
}

<*
 Phase 1: Parse a buffer and register its top-level declarations and modules into the workspace symbol table.
*>
fn bool parse_and_register(AnalyzerContext* context, String buffer, String path) => @pool()
{
	if (try existing = context.files.get(path))
	{
		source_file::free(context, existing);
	}

	Lexer* lexer = lexer::create(context, buffer);
	lexer::tokenize(lexer);

	SourceFile* source = source_file::create(context, lexer, path);

	ParseContext* parse_ctx = parser::create(context);
	defer parser::free(context, parse_ctx);

	bool parse_ok = parser::parse(parse_ctx, source);
	source.max_node_id = ast::next_node_id;

	registry::register(context, source);

	return parse_ok;
}

<*
 Phase 2: Run semantic analysis on a parsed SourceFile when all workspace modules are registered.
*>
fn bool analyze_file(AnalyzerContext* context, String path) => @pool()
{
	SourceFile* source = context.files.get(path) ?? null;
	if (!source) return false;

	SemaContext* sema_ctx = sema::create(context, tmem);
	sema::analyze_source_file(sema_ctx, source);

	return true;
}

<*
 Convenience wrapper combining parsing, registration, and analysis for standalone files and tests.
*>
fn bool process(AnalyzerContext* context, String buffer, String path) => @pool()
{
	bool parse_ok = parse_and_register(context, buffer, path);
	analyze_file(context, path);
	return parse_ok;
}

fn bool process_file(AnalyzerContext* context, String path) => @pool()
{
	String? buffer = (String)file::load(tmem, path);
	if (catch err = buffer)
	{
		diagnostics::log_error("core::process_file - failed to load file (&s) %s", err, path);
		return false;
	}

	return process(context, buffer, path);
}

<*
 @param [&in] context
 @require $Typeof(item) == POINTER : "item must be a pointer"
*>
macro void free_item(AnalyzerContext* context, item)
{
	$if $defined(item.free):
		item.free(context.allocator);
	$else
		alloc::free(context.allocator, item);
	$endif
}
