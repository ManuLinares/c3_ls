<*
 Opt-in sweep over stdlib sources: runs only when SWEEP_OUT is set. For
 every name token of the files under std/SWEEP_DIR (a directory or one
 .c3 file) it checks hover, definition, completion with the name typed and
 completion right after a `.` or `::`, and writes each miss to SWEEP_OUT
 as a tab-separated row:

   check  std-relative-path:line:col  token-kind  prev-kind  next-kind  token  line-text  [item-count]

 Checks: HOVER, DEF (no result), CMISS (the name is not offered with it
 typed; declarations skipped), AMISS (not offered right after `.`/`::`),
 AJUNK (builtin types offered right after `.`/`::`).
 test/sweep.sh runs one process per file in parallel.
*>
module lsp::stdlib_sweep_test;

import lsp, uri, std::io, std::io::path, std::io::file, std::os::env, analyzer::core, analyzer::lexer, std::collections;

fn bool is_name(TokenKind k) @local
{
	switch (k)
	{
		case IDENT:
		case TYPE_IDENT:
		case CONST_IDENT:
		case AT_IDENT:
		case AT_TYPE_IDENT:
		case CT_IDENT:
		case CT_TYPE_IDENT:
		case CT_CONST_IDENT:
		case HASH_IDENT:
			return true;
		default:
			return false;
	}
}

fn bool has_label(CompletionItem[] items, String label) @local
{
	foreach (item : items)
	{
		if (item.label == label) return true;
	}
	return false;
}

fn void sweep() @test
{
	String out_path = env::tget_var("SWEEP_OUT") ?? "";
	if (out_path.len == 0) return;
	String sub = env::tget_var("SWEEP_DIR") ?? "";
	stdlib_fixture::@with_stdlib_project(; LspProject* proj)
	{
		File out = file::open(out_path, "w")!!;
		defer (void)out.close();
		String std_root = ((String)path::tnew(server::std_path)!!.tappend("std")!!).treplace("\\", "/");
		String root = sub.len ? string::tformat("%s/%s", std_root, sub) : std_root;
		List{String} paths;
		paths.tinit();
		if (sub.ends_with(".c3"))
		{
			paths.push(root);
		}
		else
		{
			foreach (rel : path::ls(tmem, path::tnew(root)!!, no_dirs: true, recursive: true)!!)
			{
				if (((String)rel).ends_with(".c3")) paths.push(string::tformat("%s/%s", root, ((String)rel).treplace("\\", "/")));
			}
		}
		foreach (full : paths)
		{
			SourceFile* sf = proj.workspace.get_source_file_by_path(full)!!;
			if (!sf)
			{
				io::fprintfn(&out, "NOFILE\t%s", full)!!;
				continue;
			}
			Uri u = uri::from_file_path(tmem, full);
			String raw_uri = u.to_raw_string(tmem);
			String[] lines = sf.content.tsplit("\n");
			Token[] toks = sf.lexer.tokens.array_view();
			foreach (i, t : toks)
			{
				@pool()
				{
					if (!is_name(t.kind)) continue;
					LspPosition pos = { (uint)t.range.start.line, (uint)t.range.start.column };
					TokenKind prev = i > 0 ? toks[i - 1].kind : EOF;
					TokenKind next = i + 1 < toks.len ? toks[i + 1].kind : EOF;
					String row = string::tformat("%s:%d:%d\t%s\t%s\t%s\t%s\t%s", full[std_root.len + 1..], t.range.start.line + 1, t.range.start.column + 1,
						t.kind, prev, next, t.value, lines[t.range.start.line].trim());

					String h = hover::hover(proj, u, pos) ?? "";
					if (h.len == 0) io::fprintfn(&out, "HOVER\t%s", row)!!;
					LspLocation[] d = definition::goto_definition(proj, u, pos) ?? (LspLocation[]){};
					if (d.len == 0) io::fprintfn(&out, "DEF\t%s", row)!!;

					bool is_decl = d.len > 0 && d[0].uri == raw_uri && d[0].range.start.line == pos.line && d[0].range.start.character == pos.character;
					LspPosition end = { (uint)t.range.end.line, (uint)t.range.end.column };
					if (try items = completion::resolve(proj, u, end))
					{
						if (!is_decl && !has_label(items, t.value)) io::fprintfn(&out, "CMISS\t%s\t%d", row, items.len)!!;
					}

					if (prev != DOT && prev != SCOPE) continue;
					if (try after = completion::resolve(proj, u, pos))
					{
						if (has_label(after, "void") || has_label(after, "usz"))
						{
							io::fprintfn(&out, "AJUNK\t%s\t%d", row, after.len)!!;
						}
						else if (!has_label(after, t.value))
						{
							io::fprintfn(&out, "AMISS\t%s\t%d", row, after.len)!!;
						}
					}
				};
			}
		}
	};
}
