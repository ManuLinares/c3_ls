// src/analyzer/core/source_file.c3
module analyzer::core::source_file;

import analyzer::core::ast;
import analyzer::lexer;
import analyzer::parser;
import analyzer::sema;

import std::io;

fn SourceFile* create(AnalyzerContext* context, Lexer* lexer, String path, Allocator alloc = null)
{
	SourceFile* source_file = alloc::new(context.allocator, SourceFile);

	source_file.arena.init(context.allocator, 4096);

	source_file.content = lexer.buffer.copy(&source_file.arena);
	source_file.lexer = lexer;

	context.files.set(path, source_file);
	
	source_file.ast.allocator = &source_file.arena;
	source_file.ast.nodes.init(&source_file.arena);
	source_file.ast.statements.init(&source_file.arena);
	source_file.path = path.copy(&source_file.arena);
	source_file.min_node_id = ast::next_node_id;
	
	return source_file;
}

fn void unregister_source_file(AnalyzerContext* context, SourceFile* sf)
{
	if (!context || !sf) return;

	if (context.registry)
	{
		Registry* reg = context.registry;

		reg.functions.@each(; qname, head)
		{
			FunctionInfo* prev = null;
			FunctionInfo* curr = head;
			while (curr != null)
			{
				switch (sf.contains_node(curr.node))
				{
					case true:
						curr = curr.next;
						switch (prev != null)
						{
							case true:
								prev.next = curr;
							case false:
								if (try head_ptr = reg.functions.get_ref(qname))
								{
									*head_ptr = curr;
								}
						}
					case false:
						prev = curr;
						curr = curr.next;
				}
			}
		};

		reg.types.@each(; qname, head)
		{
			TypeInfo* prev = null;
			TypeInfo* curr = head;
			while (curr != null)
			{
				switch (sf.contains_node(curr.node))
				{
					case true:
						curr = curr.next;
						switch (prev != null)
						{
							case true:
								prev.next = curr;
							case false:
								if (try head_ptr = reg.types.get_ref(qname))
								{
									*head_ptr = curr;
								}
						}
					case false:
						prev = curr;
						curr = curr.next;
				}
			}
		};

		reg.macros.@each(; qname, head)
		{
			MacroInfo* prev = null;
			MacroInfo* curr = head;
			while (curr != null)
			{
				switch (sf.contains_node(curr.node))
				{
					case true:
						curr = curr.next;
						switch (prev != null)
						{
							case true:
								prev.next = curr;
							case false:
								if (try head_ptr = reg.macros.get_ref(qname))
								{
									*head_ptr = curr;
								}
						}
					case false:
						prev = curr;
						curr = curr.next;
				}
			}
		};
	}

	context.modules.@each(; mod_name, mod)
	{
		if (mod)
		{
			sz write_idx = 0;
			for (sz i = 0; i < mod.nodes.len(); i++)
			{
				Node* n = mod.nodes.get(i);
				switch (sf.contains_node(n))
				{
					case true:
						(void)mod.node_map.remove(n.id);
					case false:
						if (write_idx != i)
						{
							mod.nodes.set(write_idx, n);
						}
						write_idx++;
				}
			}
			while (mod.nodes.len() > write_idx)
			{
				(void)mod.nodes.pop();
			}

			write_idx = 0;
			for (sz i = 0; i < mod.module_decls.len(); i++)
			{
				ModuleDecl* md = mod.module_decls.get(i);
				switch (sf.contains_node((Node*)md))
				{
					case true:
						break;
					case false:
						if (write_idx != i)
						{
							mod.module_decls.set(write_idx, md);
						}
						write_idx++;
				}
			}
			while (mod.module_decls.len() > write_idx)
			{
				(void)mod.module_decls.pop();
			}
		}
	};
}

fn void free(AnalyzerContext* context, SourceFile* sf)
{
	unregister_source_file(context, sf);
	if (sf.lexer) lexer::free(context, sf.lexer);
	(void)context.files.remove(sf.path);
	sf.arena.free();
	alloc::free(context.allocator, sf);
}