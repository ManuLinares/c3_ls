module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;

import std::collections::list;
import std::collections::map;

import lsp::core;
import lsp;
import uri;

fn bool is_imported_as_public(SourceFile* sf, String target_mod)
{
	if (!sf || target_mod.len == 0) return false;

	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind != IMPORT_DECL) continue;
		ImportDecl* imp = stmt.as(ImportDecl);

		bool has_public = false;
		foreach (attr : imp.attributes)
		{
			if (attr && attr.kind == ATTRIBUTE_DECL && attr.as(AttributeDecl).attribute_kind == AttributeKind.PUBLIC)
			{
				has_public = true;
				break;
			}
		}
		if (!has_public) continue;

		foreach (p : imp.paths)
		{
			if (!p || p.kind != PATH_EXPR) continue;
			PathExpr* pe = p.as(PathExpr);
			String imp_path = pe.path ? pe.path.text.strip_suffix("::") : "";
			if (imp_path == target_mod || target_mod.starts_with(string::tformat("%s::", imp_path)))
			{
				return true;
			}
		}
	}
	return false;
}

fn bool is_symbol_accessible(SourceFile* caller_sf, String caller_mod, Node* target_node, String target_mod)
{
	if (!target_node) return false;

	Visibility vis = target_node.visibility;
	if (target_node.flags.has_attributes)
	{
		NodeArray attrs;
		switch (target_node.kind)
		{
			case FN_DECL: attrs = target_node.as(FnDecl).attributes;
			case MACRO_DECL: attrs = target_node.as(MacroDecl).attributes;
			case STRUCT_DECL: attrs = target_node.as(StructDecl).attributes;
			case ENUM_DECL: attrs = target_node.as(EnumDecl).attributes;
			case VAR_DECL: attrs = target_node.as(VarDecl).attributes;
			case TYPEDEF_DECL: attrs = target_node.as(TypedefDecl).attributes;
			case ALIAS_DECL: attrs = target_node.as(AliasDecl).attributes;
			default: break;
		}
		foreach (attr : attrs)
		{
			if (!attr || attr.kind != ATTRIBUTE_DECL) continue;
			AttributeDecl* ad = attr.as(AttributeDecl);
			if (ad.attribute_kind == AttributeKind.LOCAL)
			{
				vis = LOCAL; break;
			}
			if (ad.attribute_kind == AttributeKind.PRIVATE)
			{
				vis = PRIVATE; break;
			}
			if (ad.attribute_kind == AttributeKind.PUBLIC)
			{
				vis = PUBLIC; break;
			}
		}
	}

	if (vis == LOCAL)
	{
		return caller_sf != null && caller_sf.contains_node(target_node);
	}

	if (vis == PRIVATE)
	{
		if (caller_mod.len > 0 && target_mod.len > 0 && caller_mod == target_mod) return true;
		if (caller_sf && is_imported_as_public(caller_sf, target_mod)) return true;
		return false;
	}

	return true;
}

fn bool fuzzy_match(String target, String prefix)
{
	if (prefix.len == 0) return true;
	if (prefix.starts_with("@")) prefix = prefix[1..];
	if (target.starts_with("@")) target = target[1..];
	if (prefix.len == 0) return true;
	if (target.len < prefix.len) return false;

	if (target.starts_with(prefix)) return true;

	sz pi = 0;
	sz ti = 0;
	while (ti < target.len && pi < prefix.len)
	{
		char tc = (target[ti] >= 'A' && target[ti] <= 'Z') ? target[ti] + 32 : target[ti];
		char pc = (prefix[pi] >= 'A' && prefix[pi] <= 'Z') ? prefix[pi] + 32 : prefix[pi];
		if (tc == pc)
		{
			pi++;
		}
		ti++;
	}

	return pi == prefix.len;
}

fn void provide_keywords(Context* ctx, List{CompletionItem} * items)
{
	if (ctx.access != NONE) return;

	foreach (kw : lsp::Keywords::values)
	{
		switch (ctx.scope)
		{
			case GLOBAL:
				if (!kw.is_top_level()) continue;
				break;

			case CONTAINER:
				if (!kw.is_container()) continue;
				break;

			case EXECUTION:
				if (!kw.is_statement() && !kw.is_expression()) continue;
				break;

			case TYPE_ASSIGNMENT:
				if (!kw.is_value()) continue;
				break;
			default:
				break;
		}
		if (fuzzy_match(kw.name, ctx.prefix))
		{
			items.push(
			{
				.label = kw.name,
				.kind = KEYWORD,
				.detail = "Keyword",
				.insertText = kw.name,
				.filterText = kw.name,
				.sortText = string::tformat("0010_%s", kw.name),
			}
			);
		}
	}
}

fn void add_symbol_completion(Context* ctx, List{CompletionItem} * items, String symbol_name, Node* node, String base_identifier, String prefix = "")
{
	if (!node) return;

	CompletionItemKind item_kind = CompletionItemKind.VALUE;
	String type_desc = "Symbol";
	String insert_text = symbol_name;
	String node_type = "";

	if (prefix.len > 0 && prefix.starts_with("@"))
	{
		insert_text = symbol_name.strip_prefix("@");
	}

	InsertTextFormat format = PLAIN_TEXT;

	bool is_stmt = (ctx.scope == EXECUTION);
	if (is_stmt && ctx.sf && ctx.offset <= ctx.sf.content.len)
	{
		sz p = ctx.offset;
		while (p < ctx.sf.content.len && ctx.sf.content[p] != '\n')
		{
			if (ctx.sf.content[p] == ';') { is_stmt = false; break; }
			p++;
		}
	}

	switch (node.kind)
	{
		case FN_DECL:
			{
				FnDecl* fd = node.as(FnDecl);
				item_kind = FUNCTION;
				type_desc = "fn";
				bool is_void = false;
				if (fd.ret_type)
				{
					String rt = cursor::raw_type_identifier(fd.ret_type) ?? cursor::spelling(fd.ret_type, tmem);
					node_type = rt;
					if (rt == "void") is_void = true;
				}
				else
				{
					is_void = true;
				}

				if (is_void && is_stmt)
				{
					insert_text = string::tformat("%s($1);", insert_text);
				}
				else
				{
					insert_text = string::tformat("%s($1)", insert_text);
				}
				format = SNIPPET;
			}
		case MACRO_DECL:
			{
				MacroDecl* md = node.as(MacroDecl);
				item_kind = FUNCTION;
				type_desc = "macro";
				bool is_void = false;
				if (try rt = md.ret_type.get())
				{
					String rt_str = cursor::raw_type_identifier(rt) ?? cursor::spelling(rt, tmem);
					node_type = rt_str;
					if (rt_str == "void") is_void = true;
				}
				else
				{
					is_void = true;
				}

				if (is_void && is_stmt)
				{
					insert_text = string::tformat("%s($1);", insert_text);
				}
				else
				{
					insert_text = string::tformat("%s($1)", insert_text);
				}
				format = SNIPPET;
			}
		case INTERFACE_DECL:
			item_kind = INTERFACE;
			type_desc = "interface";
			node_type = symbol_name;
		case STRUCT_DECL:
			item_kind = STRUCT;
			type_desc = "struct";
			node_type = symbol_name;
		case ENUM_DECL:
			item_kind = ENUM;
			type_desc = "enum";
			node_type = symbol_name;
		case FAULT_DECL:
			item_kind = CONSTANT;
			type_desc = "fault";
			node_type = "fault";
		case VAR_DECL:
			{
				VarDecl* decl = node.as(VarDecl);
				if (decl.var_flags.is_const)
				{
					item_kind = CONSTANT;
					type_desc = "constant";
				}
				else
				{
					item_kind = VARIABLE;
					type_desc = "global var";
				}
				if (decl.type) node_type = cursor::raw_type_identifier(decl.type) ?? "";
			}
		default:
			break;
	}

	if (ctx.missing_second_colon && ctx.access == STATIC)
	{
		insert_text = string::tformat(":%s", insert_text);
	}

	String detail_string = string::tformat("%s via %s", type_desc, base_identifier);
	String filter_text = symbol_name.strip_prefix("@");

	String sort_prefix = "0010";
	if (ctx.expected_type.len > 0 && node_type.len > 0 && node_type == ctx.expected_type)
	{
		sort_prefix = "0001";
	}
	else if (ctx.prefix.len > 0 && symbol_name.starts_with(ctx.prefix))
	{
		sort_prefix = "0002";
	}
	else if (ctx.prefix.len > 0)
	{
		sort_prefix = "0008";
	}

	String data_str = "";
	if (base_identifier.len > 0)
	{
		data_str = string::tformat("symbol:%s:%s", base_identifier, symbol_name);
	}
	else
	{
		data_str = string::tformat("symbol:%s", symbol_name);
	}

	items.push(
	{
		.label = symbol_name,
		.kind = item_kind,
		.detail = detail_string,
		.insertText = insert_text,
		.insertTextFormat = format,
		.filterText = filter_text,
		.sortText = string::tformat("%s_%s", sort_prefix, symbol_name),
		.data = data_str
	}
	);
}

fn bool is_type_position(Context* ctx) @local
{
	if (ctx.scope == CONTAINER) return true;
	if (!ctx.sf || ctx.offset == 0 || ctx.offset > ctx.sf.content.len) return false;

	sz p = ctx.offset - ctx.prefix.len;
	while (p > 0 && (ctx.sf.content[p - 1] == ' ' || ctx.sf.content[p - 1] == '\t'))
	{
		p--;
	}
	if (p == 0) return ctx.scope == GLOBAL;

	char prev_char = ctx.sf.content[p - 1];

	// Generics e.g. List{...}, param separation e.g. (int a, ...)
	if (prev_char == '{' || prev_char == ',' || prev_char == '<') return true;

	// Typedef alias e.g. typedef Foo = ...
	if (prev_char == '=') return true;

	// Check words preceding the type
	sz word_end = p;
	while (p > 0 && (ctx.sf.content[p - 1].is_alnum() || ctx.sf.content[p - 1] == '_' || ctx.sf.content[p - 1] == '=' || ctx.sf.content[p - 1] == '>'))
	{
		p--;
	}
	String prev_word = ctx.sf.content[p : word_end - p].trim();

	// Function return type or short body
	if (prev_word == "fn" || prev_word == "macro" || prev_word == "=>") return true;

	// Variable / const qualifiers
	if (prev_word == "const" || prev_word == "static" || prev_word == "tlocal" || prev_word == "extern") return true;

	// Cast or parameter: (int) or fn foo(int x)
	if (prev_char == '(')
	{
		sz before_paren = word_end - 1;
		while (before_paren > 0 && (ctx.sf.content[before_paren - 1] == ' ' || ctx.sf.content[before_paren - 1] == '\t')) before_paren--;
		sz kw_end = before_paren;
		while (before_paren > 0 && ctx.sf.content[before_paren - 1].is_alnum()) before_paren--;
		String kw = ctx.sf.content[before_paren : kw_end - before_paren].trim();
		if (kw == "if" || kw == "while" || kw == "for" || kw == "foreach" || kw == "switch" || kw == "catch")
		{
			return false;
		}
		return true;
	}

	return false;
}

fn void provide_builtin_types(Context* ctx, List{CompletionItem} * items)
{
	if (ctx.access != NONE) return;

	bool in_type_pos = is_type_position(ctx);
	String sort_prefix = in_type_pos ? "0001" : "0020";

	// Primitives from the single source of truth in constants.c3
	foreach (tname : constants::Primitives::values)
	{
		if (fuzzy_match(tname, ctx.prefix))
		{
			items.push(
			{
				.label = tname,
				.kind = CLASS,
				.detail = "built-in type",
				.insertText = tname,
				.filterText = tname,
				.sortText = string::tformat("%s_%s", sort_prefix, tname),
				.data = "property"
			}
			);
		}
	}

	// String is defined in std::core, but ubiquitously used as a base type
	if (fuzzy_match("String", ctx.prefix))
	{
		items.push(
		{
			.label = "String",
			.kind = CLASS,
			.detail = "built-in type",
			.insertText = "String",
			.filterText = "String",
			.sortText = string::tformat("%s_String", sort_prefix),
			.data = "property"
		}
		);
	}
}