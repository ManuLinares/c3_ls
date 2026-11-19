module analyzer::core::source_file;

import analyzer::core::ast;
import analyzer::core::mod;
import analyzer::lexer;
import analyzer::parser;
import analyzer::sema;

import std::collections::list;
import std::sort;
import std::io;

fn SourceFile* create(AnalyzerContext* context, Lexer* lexer, String path, Allocator alloc = null)
{
	SourceFile* source_file = alloc::new(context.allocator, SourceFile);

	source_file.arena.init(context.allocator, 4096);

	source_file.content = lexer.buffer.copy(&source_file.arena);
	source_file.lexer = lexer;

	source_file.identifiers.init(&source_file.arena);
	foreach (&tok : lexer.tokens)
	{
		sz offset = tok.value.ptr - lexer.buffer.ptr;
		if (offset >= 0 && offset + tok.value.len <= lexer.buffer.len) tok.value = source_file.content[offset : tok.value.len];
		if (tok.kind.is_identifier()) source_file.identifiers.add(tok.value);
	}
	lexer.buffer = source_file.content;

	context.files.set(path, source_file);

	source_file.ast.allocator = &source_file.arena;
	source_file.ast.nodes.init(&source_file.arena);
	source_file.ast.statements.init(&source_file.arena);
	source_file.ast.module_decls.init(&source_file.arena);
	source_file.path = path.copy(&source_file.arena);
	source_file.min_node_id = ast::next_node_id;
	context.files_by_node_id.push(source_file);

	return source_file;
}

<*
 File whose AST owns `node`, or null.
*>
fn SourceFile* file_of(AnalyzerContext* context, Node* node)
{
	if (!node) return null;
	SourceFile*[] files = context.files_by_node_id.array_view();
	sz index = sort::binarysearch(files, null, &starts_after, &node.id) - 1;
	return index >= 0 && files[index].contains_node(node) ? files[index] : null;
}

<*
 Never equal, so a binary search ends past every file starting at or before `id`.
*>
fn int starts_after(SourceFile* file, SourceFile* unused, NodeID* id) @local => file.min_node_id <= *id ? -1 : 1;

<*
 Removes from the registry map `#map` the entries declared in `sf`, and the
 names left without entries.
*>
macro void @drop_entries_of(#map, SourceFile* sf)
{
	List{String} emptied;
	emptied.tinit();
	#map.@each(; name, head)
	{
		$Typeof(head) prev = null;
		$Typeof(head) curr = head;
		while (curr)
		{
			$Typeof(head) next = curr.next;
			if (!sf.contains_node(curr.node))
			{
				prev = curr;
			}
			else if (prev)
			{
				prev.next = next;
			}
			else
			{
				*#map.get_ref(name)!! = next;
			}
			curr = next;
		}
		if (!(#map.get(name) ?? null)) emptied.push(name);
	};
	foreach (name : emptied) (void)#map.remove(name);
}

fn void unregister_source_file(AnalyzerContext* context, SourceFile* sf)
{
	if (!context || !sf) return;

	if (context.registry)
	{
		Registry* reg = context.registry;
		@drop_entries_of(reg.functions, sf);
		@drop_entries_of(reg.types, sf);
		@drop_entries_of(reg.macros, sf);
		@drop_entries_of(reg.attrmacros, sf);
		@drop_entries_of(reg.methods_by_type, sf);
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

	// Clean up any module entry that has no declarations left
	List{String} empty_mods;
	empty_mods.tinit();
	context.modules.@each(; m_name, m)
	{
		if (m && m.nodes.len() == 0 && m.module_decls.len() == 0)
		{
			empty_mods.push(m_name);
		}
	};
	foreach (m_name : empty_mods)
	{
		if (try m = context.modules.get(m_name))
		{
			mod::free(context, m);
			(void)context.modules.remove(m_name);
		}
	}
}

fn void free(AnalyzerContext* context, SourceFile* sf)
{
	unregister_source_file(context, sf);
	if (sf.lexer) lexer::free(context, sf.lexer);
	(void)context.files.remove(sf.path);
	context.files_by_node_id.remove_first_item(sf);
	sf.arena.free();
	alloc::free(context.allocator, sf);
}