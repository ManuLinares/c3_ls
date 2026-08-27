module analyzer::sema;

import analyzer::core;
import analyzer::cursor;

import analyzer::core::diagnostics;

import std::collections::map;
import std::collections::list;
import std::collections::set;

struct SemaContext
{
	AnalyzerContext* context;
	Allocator allocator;
	Scope* scope;
	HashMap{String, ImportInfo} imports;
}

fn SemaContext* create(AnalyzerContext* context, Allocator alloc = tmem)
{
	SemaContext* ctx = alloc::new(alloc, SemaContext);

	ctx.context = context;
	ctx.allocator = alloc;
	ctx.scope = scope::create(alloc, {});
	ctx.imports.init(alloc);

	return ctx;
}

<*
 @require ctx.context != null
*>
fn void analyze_source_file(SemaContext* ctx, SourceFile* sf)
{
	ctx.context.current_source_file = sf;

	ctx.scope = scope::create(ctx.allocator, {});

	analyze_imports(ctx);

	run_variable_pass(ctx);
}

fn void analyze_imports(SemaContext* ctx)
{
	foreach (Node* node : ctx.context.current_source_file.ast.statements)
	{
		if (node.kind != IMPORT_DECL) continue;

		ImportDecl* imp = node.as(ImportDecl);

		foreach (Node* path : imp.paths)
		{
			if (!path || path.kind != PATH_EXPR) continue;
			PathExpr* expr = path.as(PathExpr);
			String full_path = expr.path ? expr.path.text.strip_suffix("::") : "";
			if (full_path.len == 0) continue;

			bool found_module = ctx.context.modules.has_key(full_path);
			if (!found_module)
			{
				String prefix = string::tformat("%s::", full_path);
				String suffix = string::tformat("::%s", full_path);
				ctx.context.modules.@each(; mod_name, m)
				{
					if (mod_name.starts_with(prefix) || mod_name.ends_with(suffix))
					{
						found_module = true;
						break;
					}
				};
			}

			if (!found_module)
			{
				diagnostics::error(ctx.context, expr.range, "No module '%s' found", full_path);
				continue;
			}

			if (!ctx.imports.has_key(full_path))
			{
				diagnostics::log_debug("[AnalyzeImports]: Added import '%s'", full_path);
				ctx.imports.set(full_path, { full_path, node });
			}

			if (!cursor::has_attribute(imp, NORECURSE, null))
			{
				sz offset = 0;
				while (try idx = full_path[offset..].index_of("::"))
				{
					sz break_pos = offset + idx;
					String parent_prefix = full_path[:break_pos];

					if (!ctx.imports.has_key(parent_prefix) && ctx.context.modules.has_key(parent_prefix))
					{
						diagnostics::log_debug("[AnalyzeImports]: Added recursive import '%s'", parent_prefix);
						ctx.imports.set(parent_prefix, { full_path, node });
					}

					offset = break_pos + 2;
				}
			}

			if (try idx = full_path.rindex_of("::"))
			{
				String leaf = full_path[idx + 2..];
				if (!ctx.imports.has_key(leaf) && ctx.context.modules.has_key(leaf))
				{
					diagnostics::log_debug("[AnalyzeImports]: Added leaf import '%s'", leaf);
					ctx.imports.set(leaf, { full_path, node });
				}
			}
		}
	}
}
