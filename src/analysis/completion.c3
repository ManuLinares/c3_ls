module lsp::analysis::completion;
import analyzer::core, analyzer::cursor, analyzer::lexer, analyzer::parser, analyzer::sema, std::collections, lsp, uri;

enum ScopeKind
{
	NONE,
	IMPORT,
	GLOBAL,
	PARAMETER,
	CONTAINER,
	ENUM,
	EXECUTION,
	EXPRESSION,
	TYPE_ASSIGNMENT,
	ATTRIBUTE
}

enum AttributeTargetKind : char
{
	NONE,
	ANY,
	FUNCTION,
	TYPE,
	VARIABLE,
	FIELD,
	ENUM,
	ENUM_MEMBER,
	MODULE,
	IMPORT,
	PARAMETER,
	CALL,
	ATTRDEF,
	SWITCH
}

enum LspAccessKind
{
	NONE,
	INSTANCE,
	STATIC
}

struct Context
{
	Uri uri;
	LspPosition position;
	<* `position` as an analyzer location. *>
	Location loc;
	sz offset;
	LspWorkspace* ws;
	SourceFile* sf;
	Allocator allocator;
	String prefix;
	ScopeKind scope;
	AttributeTargetKind attr_target;
	LspAccessKind access;
	String base_identifier;
	String expected_type;
	String caller_mod;
	bool missing_second_colon;
	bool is_designated_initializer;
	bool designated_has_dot;
	Node* switch_node;
	bool is_stmt;
}

struct LocalCollectorContext
{
	Context* ctx;
	Location loc;
	List{CompletionItem}* items;
	HashSet{String} seen;
}

// ---------------------------------------------------------------------------
// Matching & Common Helpers
// ---------------------------------------------------------------------------

<*
 Replaces the typed prefix with `text`; needed where the client does not count the prefix's sigil as part of the word.
*>
fn TextEdit* replace_typed(Context* ctx, String text) @local
{
	LspPosition start = { .line = ctx.position.line, .character = ctx.position.character - (uint)ctx.prefix.len };
	return alloc::new(tmem, TextEdit, { .range = { .start = start, .end = ctx.position }, .newText = text });
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

fn bool has_lparen_ahead(Context* ctx) @local
{
	if (!ctx.sf) return false;
	sz scan = ctx.offset;
	while (scan < ctx.sf.content.len && (ctx.sf.content[scan] == ' ' || ctx.sf.content[scan] == '\t')) scan++;
	return scan < ctx.sf.content.len && ctx.sf.content[scan] == '(';
}

<*
 Whether the completed word directly follows `=>`, so it starts an expression body.
*>
fn bool follows_arrow(Context* ctx) @local
{
	if (!ctx.sf || ctx.offset > ctx.sf.content.len) return false;
	sz p = ctx.offset - ctx.prefix.len;
	while (p > 0 && (ctx.sf.content[p - 1] == ' ' || ctx.sf.content[p - 1] == '\t')) p--;
	return p >= 2 && ctx.sf.content[p - 2:2] == "=>";
}

fn void append_snippet_text(DString* out, String text) @local
{
	foreach (c : text)
	{
		if (c == '$' || c == '}' || c == '\\') out.append_char('\\');
		out.append_char(c);
	}
}

<*
 Call text for a function or macro: required parameters become placeholders,
 body parameters keep their declared names, which are valid as written, and a
 trailing body gets a block holding the cursor.
 Parameters with defaults and variadic parameters are left out, so required
 parameters after a left-out one are named.
*>
fn String call_insert_text(Context* ctx, String name, NodeArray params, bool is_method, Node* body_params, bool is_void, InsertTextFormat* format) @local
{
	*format = PLAIN_TEXT;
	if (has_lparen_ahead(ctx)) return name;

	DString out;
	out.tinit();
	out.append(name);
	out.append_char('(');
	int tabstop = 1;
	bool skipped = false;
	bool first = true;
	foreach (i, param : params)
	{
		if (i == 0 && is_method) continue;
		if (!param || param.kind != VAR_DECL) continue;
		VarDecl* vd = param.as(VarDecl);
		if (!vd.name || vd.var_flags.is_variadic || vd.var_flags.is_macro_optional_ellipsis) continue;
		if (vd.init_expr)
		{
			skipped = true;
			continue;
		}
		if (!first) out.append(", ");
		first = false;
		if (skipped) out.appendf("%s: ", vd.name.text);
		out.appendf("${%d:", tabstop++);
		append_snippet_text(&out, vd.name.text);
		out.append_char('}');
	}

	BodyParamDecl* body = body_params && body_params.kind == BODY_PARAM_DECL ? body_params.as(BodyParamDecl) : null;
	if (body)
	{
		bool has_body_names;
		foreach (param : body.params)
		{
			if (!param || param.kind != VAR_DECL || !param.as(VarDecl).name) continue;
			out.append(has_body_names ? ", " : "; ");
			has_body_names = true;
			append_snippet_text(&out, param.as(VarDecl).name.text);
		}
		out.append(")\n{\n\t$0\n}");
		if (ctx.is_stmt && !follows_arrow(ctx)) out.append_char(';');
		*format = SNIPPET;
		return out.str_view();
	}

	out.append_char(')');
	if (is_void && ctx.is_stmt) out.append_char(';');
	if (tabstop > 1) *format = SNIPPET;
	return out.str_view();
}

fn void add_symbol_completion(
	Context* ctx,
	List{CompletionItem}* items,
	String symbol_name,
	Node* node,
	String base_identifier,
	String prefix = "",
	String qualifier = ""
)
{
	if (!node) return;

	CompletionItemKind item_kind = analysis::to_completion_kind(node);
	String insert_text = symbol_name;
	String node_type = "";

	bool replaces_typed_at = qualifier.len > 0 && prefix.starts_with("@");
	if (qualifier.len > 0)
	{
		insert_text = string::tformat("%s%s", qualifier, symbol_name);
	}
	else if (prefix.starts_with("@"))
	{
		insert_text = symbol_name.strip_prefix("@");
	}

	InsertTextFormat format = PLAIN_TEXT;

	switch (node.kind)
	{
		case FN_DECL:
			{
				FnDecl* fd = node.as(FnDecl);
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

				insert_text = call_insert_text(ctx, insert_text, fd.params, fd.associated_type != null, null, is_void, &format);
			}
		case MACRO_DECL:
			{
				MacroDecl* md = node.as(MacroDecl);
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

				insert_text = call_insert_text(ctx, insert_text, md.params, @ok(md.associated_type.get()), md.body_params, is_void, &format);
			}
		case INTERFACE_DECL:
		case STRUCT_DECL:
		case ENUM_DECL:
			node_type = symbol_name;
		case FAULT_DECL:
			node_type = "fault";
		case VAR_DECL:
			{
				VarDecl* decl = node.as(VarDecl);
				if (decl.type) node_type = cursor::raw_type_identifier(decl.type) ?? "";
			}
		default:
			break;
	}

	if (ctx.missing_second_colon && ctx.access == STATIC)
	{
		insert_text = string::tformat(":%s", insert_text);
	}

	String filter_text = symbol_name.strip_prefix("@");
	TextEdit* text_edit = null;
	if (replaces_typed_at)
	{
		// The client leaves the typed `@` in place, so the module path can only go before it by replacing it.
		text_edit = replace_typed(ctx, insert_text);
		filter_text = symbol_name;
	}

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
		.detail = declaration::signature(ctx.ws.ctx, node, symbol_name, true),
		.insertText = insert_text,
		.insertTextFormat = format,
		.filterText = filter_text,
		.sortText = string::tformat("%s_%s", sort_prefix, symbol_name),
		.data = data_str,
		.textEdit = text_edit
	}
	);
}

<*
 Whether the cursor follows a `(` that no callee or keyword precedes, which
 opens a cast or a group: types rank first there, values still fit.
*>
fn bool may_open_cast(Context* ctx) @local
{
	if (!ctx.sf || ctx.offset == 0 || ctx.offset > ctx.sf.content.len) return false;
	String text = ctx.sf.content[:ctx.offset - ctx.prefix.len].trim_right(" \t");
	if (!text.ends_with("(")) return false;
	text = text[:^1].trim_right(" \t");
	return !text.len || (!text[^1].is_alnum() && text[^1] != '_' && text[^1] != ')' && text[^1] != ']');
}

fn bool is_type_position(Context* ctx)
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

	if (prev_char == '{')
	{
		sz bp = p - 1;
		while (bp > 0 && (ctx.sf.content[bp - 1] == ' ' || ctx.sf.content[bp - 1] == '\t')) bp--;
		sz word_end = bp;
		while (bp > 0 && lexer::is_ident(ctx.sf.content[bp - 1])) bp--;
		if (word_end > bp && ctx.sf.content[bp] >= 'A' && ctx.sf.content[bp] <= 'Z') return true;
		return false;
	}

	if (prev_char == '<') return true;

	if (prev_char == '=')
	{
		if (ctx.scope == TYPE_ASSIGNMENT) return false;

		Location loc = { (int)ctx.position.line, (int)ctx.position.character };
		foreach (stmt : ctx.sf.ast.statements)
		{
			if (stmt && stmt.range.contains(loc))
			{
				return stmt.kind == TYPEDEF_DECL || stmt.kind == ALIAS_DECL;
			}
		}
		return false;
	}

	sz word_end = p;
	while (p > 0 && (lexer::is_ident(ctx.sf.content[p - 1]) || ctx.sf.content[p - 1] == '=' || ctx.sf.content[p - 1] == '>'))
	{
		p--;
	}
	String prev_word = ctx.sf.content[p : word_end - p].trim();

	if (prev_word == "fn" || prev_word == "macro") return true;
	if (prev_word == "const" || prev_word == "static" || prev_word == "tlocal" || prev_word == "extern" || prev_word == "inline") return true;

	if (prev_char == ':')
	{
		sz line_start = p - 1;
		while (line_start > 0 && ctx.sf.content[line_start - 1] != '\n') line_start--;
		String line_prefix = ctx.sf.content[line_start : p - 1 - line_start].trim_left();
		sz kw_end = 0;
		while (kw_end < line_prefix.len && !line_prefix[kw_end].is_space()) kw_end++;
		return constants::keyword_has_type_colon(line_prefix[:kw_end]);
	}

	if (prev_char == '(' || prev_char == ',')
	{
		sz scan = p - 1;
		while (scan > 0 && (ctx.sf.content[scan - 1] == ' ' || ctx.sf.content[scan - 1] == '\t')) scan--;
		sz kw_end = scan;
		while (scan > 0 && lexer::is_ident(ctx.sf.content[scan - 1])) scan--;
		String kw = ctx.sf.content[scan : kw_end - scan].trim();
		if (kw == "if" || kw == "while" || kw == "for" || kw == "foreach" || kw == "switch" || kw == "catch")
		{
			return false;
		}
		Location loc = { (int)ctx.position.line, (int)ctx.position.character };
		foreach (stmt : ctx.sf.ast.statements)
		{
			if (stmt && stmt.range.contains(loc) && (stmt.kind == FN_DECL || stmt.kind == MACRO_DECL))
			{
				Node* body = (stmt.kind == FN_DECL) ? stmt.as(FnDecl).body : stmt.as(MacroDecl).body;
				if (!body || !body.range.contains(loc)) return true;
			}
		}
		// Elsewhere `(` opens a call, a cast or a group: values fit as well as types.
		return false;
	}

	return false;
}

// ---------------------------------------------------------------------------
// Candidate Providers
// ---------------------------------------------------------------------------

fn bool is_matching_target(AttributeTargetMask mask, AttributeTargetKind target)
{
	switch (target)
	{
		case ANY:
		case ATTRDEF:
			return true;
		case FUNCTION:
			return mask.is_function;
		case TYPE:
			return mask.is_type;
		case VARIABLE:
			return mask.is_variable;
		case FIELD:
			return mask.is_field;
		case ENUM:
			return mask.is_enum;
		case ENUM_MEMBER:
			return mask.is_enum_member;
		case MODULE:
			return mask.is_module;
		case IMPORT:
			return mask.is_import;
		case PARAMETER:
			return mask.is_parameter;
		case CALL:
			return mask.is_call;
		case SWITCH:
			return mask.is_switch;
		default:
			return false;
	}
}

fn void provide_keywords(Context* ctx, List{CompletionItem}* items)
{
	if (ctx.access != NONE) return;

	foreach (kw : constants::Keyword::values)
	{
		switch (ctx.scope)
		{
			case GLOBAL:
				if (!kw.flags.is_top_level) continue;
			case CONTAINER:
				if (!kw.flags.is_container) continue;
			case EXECUTION:
				if (!kw.flags.is_statement && !kw.flags.is_expression) continue;
			case EXPRESSION:
			case TYPE_ASSIGNMENT:
				if (!kw.flags.is_expression) continue;
			default:
				break;
		}
		bool compile_time = kw.name[0] == '$';
		if (compile_time != ctx.prefix.starts_with("$")) continue;
		if (!fuzzy_match(kw.name, ctx.prefix)) continue;
		items.push(
		{
			.label = kw.name,
			.kind = KEYWORD,
			.detail = "Keyword",
			.insertText = kw.snippet ?: kw.name,
			.insertTextFormat = kw.snippet.len ? SNIPPET : PLAIN_TEXT,
			.filterText = kw.name,
			.sortText = string::tformat("0010_%s", kw.name)
		}
		);
	}
}

<*
 Labels of the statements enclosing `loc` that `jump` can name.
*>
fn void provide_labels(Context* ctx, List{CompletionItem}* items, Location loc, TokenKind jump) @local
{
	foreach (i, stmt : query::enclosing_labeled(ctx.sf, loc))
	{
		String name = query::label_of(stmt).text;
		if (!fuzzy_match(name, ctx.prefix)) continue;
		switch (jump)
		{
			case CONTINUE:
				if (stmt.kind != FOR_STMT && stmt.kind != FOREACH_STMT && stmt.kind != WHILE_STMT && stmt.kind != DO_WHILE_STMT) continue;
			case NEXTCASE:
				if (stmt.kind == SWITCH_STMT) break;
				Node* cond = stmt.kind == IF_STMT ? stmt.as(IfStmt).condition : null;
				if (!cond || cond.kind != COND_EXPR) continue;
				NodeArray exprs = cond.as(CondExpr).exprs;
				if (!exprs.len || exprs[^1].kind != CATCH_EXPR) continue;
			default:
				break;
		}
		items.push(
		{
			.label = name,
			.kind = REFERENCE,
			.detail = declaration::text(ctx.ws.ctx, stmt, true),
			.insertText = jump == NEXTCASE ? string::tformat("%s: ", name) : name,
			.filterText = name,
			.sortText = string::tformat("0000_%04d", i)
		}
		);
	}
}

fn void provide_builtin_types(Context* ctx, List{CompletionItem}* items)
{
	if (ctx.access != NONE) return;

	String sort_prefix = is_type_position(ctx) || may_open_cast(ctx) ? "0001" : "0020";

	foreach (pt : constants::PrimitiveType::values)
	{
		if (fuzzy_match(pt.name, ctx.prefix))
		{
			bool compile_time = pt.kind == COMPILE_TIME;
			items.push(
			{
				.label = pt.name,
				.kind = CLASS,
				.detail = compile_time ? "compile-time type" : "built-in type",
				.documentation = {
					.kind = MARKDOWN,
					.value = pt.doc
				},
				.insertText = pt.name,
				.filterText = pt.name,
				.sortText = string::tformat("%s%s_%s", sort_prefix, compile_time ? "z" : "", pt.name),
				.data = "property"
			}
			);
		}
	}

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

fn void provide_builtin_attributes_for_target(Context* ctx, List{CompletionItem}* items, AttributeTargetKind target)
{
	String sort_prefix = "0001";

	foreach (attr : AttributeKind::values)
	{
		if (attr == AttributeKind.NONE) continue;
		if (!is_matching_target(attr.targets, target)) continue;
		if (!fuzzy_match(attr.str, ctx.prefix)) continue;

		String bare = attr.str[1..];
		String ins = ctx.prefix.starts_with("@") ? bare : attr.str;
		items.push(
		{
			.label = attr.str,
			.kind = KEYWORD,
			.detail = "built-in attribute",
			.documentation = {
				.kind = MARKDOWN,
				.value = attr.doc
			},
			.insertText = ins,
			.filterText = bare,
			.sortText = string::tformat("%s_%s", sort_prefix, attr.str),
			.data = "property"
		}
		);
	}
}

fn void provide_attrmacros(Context* ctx, List{CompletionItem}* items)
{
	if (!ctx.ws || !ctx.ws.ctx || !ctx.ws.ctx.registry) return;

	String sort_prefix = "0002";

	ctx.ws.ctx.registry.attrmacros.@each(; qname, attr_info)
	{
		if (!attr_info || !attr_info.node) return;
		AttrdefDecl* ad = attr_info.node.as(AttrdefDecl);
		String aname = ad.name ? ad.name.text : "";
		if (aname.len == 0) return;

		Location loc = { (int)ctx.position.line, (int)ctx.position.character };
		if (query::is_symbol_accessible_at(ctx.ws.ctx, ctx.sf, loc, attr_info.node, attr_info.mod))
		{
			if (fuzzy_match(aname, ctx.prefix))
			{
				String bare = aname.strip_prefix("@");
				String ins = ctx.prefix.starts_with("@") ? bare : aname;
				items.push(
				{
					.label = aname,
					.kind = KEYWORD,
					.detail = declaration::signature(ctx.ws.ctx, attr_info.node, aname, true),
					.documentation = {
						.kind = MARKDOWN,
						.value = declaration::docs(attr_info.node)
					},
					.insertText = ins,
					.filterText = bare,
					.sortText = string::tformat("%s_%s", sort_prefix, aname),
					.data = string::tformat("symbol:%s:%s", attr_info.mod, aname)
				}
				);
			}
		}
	};
}

fn void provide_module_paths(Context* ctx, List{CompletionItem}* items, SourceFile* sf = null, sz offset = 0)
{
	if (!ctx.ws || !ctx.ws.ctx) return;

	String base_path = "";
	String filter_prefix = "";
	bool missing_second_colon = false;

	if (sf && offset > 0 && offset <= sf.content.len)
	{
		String line_prefix = utils::extract_line_prefix(sf.content, offset);
		bool is_import = line_prefix.starts_with("import");
		bool is_module = line_prefix.starts_with("module");

		if (is_import || is_module)
		{
			String mod_text = is_module ? line_prefix.strip_prefix("module").trim_left() : line_prefix.strip_prefix("import").trim_left();
			if (is_import)
			{
				if (try comma_idx = mod_text.rindex_of_char(','))
				{
					mod_text = mod_text[comma_idx + 1..].trim_left();
				}
			}

			if (mod_text.ends_with("::"))
			{
				base_path = mod_text[:^2].trim();
			}
			else if (mod_text.ends_with(":"))
			{
				base_path = mod_text[:^1].trim();
				missing_second_colon = true;
			}
			else if (try scope_idx = mod_text.rindex_of("::"))
			{
				base_path = mod_text[:scope_idx].trim();
				filter_prefix = mod_text[scope_idx + 2..].trim();
			}
			else
			{
				filter_prefix = mod_text.trim();
			}
		}
	}

	HashSet{String} seen_labels;
	seen_labels.tinit();

	ctx.ws.ctx.modules.@each(; mod_name, mod)
	{
		if (mod_name.len == 0) return;

		String doc_text = "";
		if (mod && mod.module_decls.len() > 0)
		{
			doc_text = cursor::docs((Node*)mod.module_decls.get(0)) ?? "";
		}

		if (base_path.len == 0)
		{
			if (filter_prefix.len == 0 || mod_name.starts_with(filter_prefix))
			{
				if (seen_labels.add(mod_name))
				{
					items.push(
					{
						.label = mod_name,
						.kind = MODULE,
						.detail = "module",
						.documentation = {
							.kind = MARKDOWN,
							.value = doc_text.len > 0 ? doc_text.trim().treplace("\"", "") : ""
						},
						.insertText = mod_name,
						.filterText = mod_name,
						.sortText = string::tformat("0009_%s", mod_name),
						.data = string::tformat("module:%s", mod_name)
					}
					);
				}
			}
		}
		else
		{
			String prefix_match = string::tformat("%s::", base_path);
			if (mod_name.starts_with(prefix_match))
			{
				String remaining = mod_name[prefix_match.len..];
				String segment = remaining;
				if (try next_colon = remaining.index_of("::"))
				{
					segment = remaining[:next_colon];
				}

				if (filter_prefix.len == 0 || segment.starts_with(filter_prefix))
				{
					if (seen_labels.add(segment))
					{
						String full_mod_name = string::tformat("%s::%s", base_path, segment);
						String insert_str = missing_second_colon ? string::tformat(":%s", segment) : segment;
						items.push(
						{
							.label = segment,
							.kind = MODULE,
							.detail = string::tformat("module %s", full_mod_name),
							.documentation = {
								.kind = MARKDOWN,
								.value = doc_text.len > 0 ? doc_text.trim().treplace("\"", "") : ""
							},
							.insertText = insert_str,
							.filterText = segment,
							.sortText = string::tformat("0001_%s", segment),
							.data = string::tformat("module:%s", full_mod_name)
						}
						);
					}
				}
			}
		}
	};
}

fn ChildVisitResult collect_locals_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	LocalCollectorContext* lctx = (LocalCollectorContext*)user_data;

	// Parameters are in scope in the whole declaration, its contract included.
	bool is_param = c.kind == VAR_DECL && c.as(VarDecl).var_kind >= VAR_PARAM;
	if (!is_param && lctx.loc.before(c.range.start)) return CONTINUE;

	switch (c.kind)
	{
		case VAR_DECL:
			{
				VarDecl* vd = c.as(VarDecl);
				String vname = vd.name ? vd.name.text : "";
				if (vname.len > 0 && fuzzy_match(vname, lctx.ctx.prefix))
				{
					String vtype = vd.type ? (cursor::spelling(vd.type, tmem) ?: "var") : "var";
					if (lctx.seen.add(vname))
					{
						String sort_prefix = "0001";
						if (lctx.ctx.expected_type.len > 0)
						{
							sort_prefix = (vtype == lctx.ctx.expected_type) ? "0000" : "0003";
						}
						lctx.items.push(
						{
							.label = vname,
							.kind = VARIABLE,
							.detail = vtype,
							.insertText = vname,
							.filterText = vname,
							.sortText = string::tformat("%s_%s", sort_prefix, vname),
							.data = string::tformat("local:%s", vname)
						}
						);
					}
				}
			}
		case TRY_EXPR:
			{
				TryExpr* te = c.as(TryExpr);
				if (!te.variable || te.variable.kind != IDENT_EXPR) break;
				IdentExpr* ie = te.variable.as(IdentExpr);
				String vname = ie.ident ? ie.ident.text : "";
				if (vname.len == 0 || (lctx.ctx.prefix.len > 0 && !vname.starts_with(lctx.ctx.prefix))) break;
				if (!lctx.seen.add(vname)) break;

				String vtype = te.type ? (cursor::spelling(te.type, tmem) ?: "var") : "var";
				if (vtype == "var" && te.init && lctx.ctx.ws && lctx.ctx.ws.ctx)
				{
					String itype = query::type_of(lctx.ctx.ws.ctx, lctx.ctx.sf, te.init, lctx.loc);
					itype = itype.trim_right("?*& \t");
					if (itype.len > 0) vtype = itype;
				}
				String sort_prefix = "0001";
				if (lctx.ctx.expected_type.len > 0)
				{
					sort_prefix = (vtype == lctx.ctx.expected_type) ? "0000" : "0003";
				}
				lctx.items.push(
				{
					.label = vname,
					.kind = VARIABLE,
					.detail = vtype,
					.insertText = vname,
					.filterText = vname,
					.sortText = string::tformat("%s_%s", sort_prefix, vname),
					.data = string::tformat("local:%s", vname)
				}
				);
			}
		case CATCH_EXPR:
			{
				CatchExpr* ce = c.as(CatchExpr);
				if (ce.variable && ce.variable.kind == IDENT_EXPR)
				{
					IdentExpr* ie = ce.variable.as(IdentExpr);
					String vname = ie.ident ? ie.ident.text : "";
					if (vname.len > 0 && (lctx.ctx.prefix.len == 0 || vname.starts_with(lctx.ctx.prefix)))
					{
						if (lctx.seen.add(vname))
						{
							String vtype = ce.type ? (cursor::spelling(ce.type, tmem) ?: "fault") : "fault";
							String sort_prefix = "0001";
							if (lctx.ctx.expected_type.len > 0)
							{
								sort_prefix = (vtype == lctx.ctx.expected_type) ? "0000" : "0003";
							}
							lctx.items.push(
							{
								.label = vname,
								.kind = VARIABLE,
								.detail = vtype,
								.insertText = vname,
								.filterText = vname,
								.sortText = string::tformat("%s_%s", sort_prefix, vname),
								.data = string::tformat("local:%s", vname)
							}
							);
						}
					}
				}
			}
		case FOREACH_STMT:
			{
				ForeachStmt* fst = c.as(ForeachStmt);
				if (fst.index && fst.index.kind == VAR_DECL)
				{
					VarDecl* ivd = fst.index.as(VarDecl);
					String iname = ivd.name ? ivd.name.text : "";
					if (iname.len > 0 && (lctx.ctx.prefix.len == 0 || iname.starts_with(lctx.ctx.prefix)))
					{
						if (lctx.seen.add(iname))
						{
							lctx.items.push(
							{
								.label = iname,
								.kind = VARIABLE,
								.detail = "sz",
								.insertText = iname,
								.filterText = iname,
								.sortText = string::tformat("0001_%s", iname),
								.data = string::tformat("local:%s", iname)
							}
							);
						}
					}
				}
				if (fst.variable && fst.variable.kind == VAR_DECL)
				{
					VarDecl* vvd = fst.variable.as(VarDecl);
					String vname = vvd.name ? vvd.name.text : "";
					if (vname.len > 0 && (lctx.ctx.prefix.len == 0 || vname.starts_with(lctx.ctx.prefix)))
					{
						if (lctx.seen.add(vname))
						{
							String vtype = vvd.type ? (cursor::spelling(vvd.type, tmem) ?: "var") : "var";
							lctx.items.push(
							{
								.label = vname,
								.kind = VARIABLE,
								.detail = vtype,
								.insertText = vname,
								.filterText = vname,
								.sortText = string::tformat("0001_%s", vname),
								.data = string::tformat("local:%s", vname)
							}
							);
						}
					}
				}
			}
		default:
			break;
	}

	return RECURSE;
}

<*
 Generic parameters in scope at the cursor.
*>
fn void provide_generic_params(Context* ctx, List{CompletionItem}* items) @local
{
	if (ctx.access != NONE || !ctx.ws || !ctx.ws.ctx) return;
	Location loc = { (int)ctx.position.line, (int)ctx.position.character };
	foreach (param : query::generic_params_at(ctx.ws.ctx, ctx.sf, loc))
	{
		String name = query::generic_param_name(param);
		if (!name.len || !fuzzy_match(name, ctx.prefix)) continue;
		items.push({
			.label = name,
			.kind = TYPEPARAMETER,
			.detail = "generic parameter",
			.insertText = name,
			.filterText = name,
			.sortText = string::tformat("0001_%s", name)
		});
	}
}

fn void provide_locals(Context* ctx, List{CompletionItem}* items)
{
	if (ctx.access != NONE || !ctx.sf) return;

	Location loc = {
		.line = (int)ctx.position.line,
		.column = (int)ctx.position.character
	};

	Node* enclosing_fn = null;
	foreach (stmt : ctx.sf.ast.statements)
	{
		if (stmt && stmt.range.contains(loc))
		{
			enclosing_fn = stmt;
			break;
		}
	}

	if (!enclosing_fn) return;

	LocalCollectorContext lctx = {
		.ctx = ctx,
		.loc = loc,
		.items = items
	};
	lctx.seen.tinit();

	cursor::visit(enclosing_fn, null, {.on_enter = &collect_locals_callback }, &lctx);
}

fn String extract_named_arg_identifier(String arg_str) @local
{
	String s = arg_str.trim();
	if (s.len == 0) return "";
	if (s.starts_with("#") || s.starts_with("$")) s = s[1..];
	if (s.len == 0 || (!s[0].is_alpha() && s[0] != '_')) return "";

	sz i = 0;
	while (i < s.len && lexer::is_ident(s[i])) i++;

	String name = s[:i];
	while (i < s.len && (s[i] == ' ' || s[i] == '\t')) i++;

	if (i < s.len && s[i] == ':' && (i + 1 == s.len || s[i + 1] != ':'))
	{
		return name;
	}

	return "";
}

fn void provide_named_args(Context* ctx, List{CompletionItem}* items)
{
	if (!ctx.sf || ctx.offset == 0 || !ctx.ws || !ctx.ws.ctx) return;

	CallTargetInfo target_info = utils::parse_call_context(ctx.sf.content, ctx.offset);
	if (!target_info.is_valid || target_info.callee_name.len == 0) return;

	CallTarget target = analysis::call_target_of(ctx.ws.ctx, ctx.sf, target_info);
	NodeArray params = target.params;
	if (params.len == 0) return;

	sz start_idx = target.first_param;

	String args_text = "";
	if (ctx.offset > target_info.open_paren_idx + 1)
	{
		args_text = ctx.sf.content[target_info.open_paren_idx + 1 : ctx.offset - (target_info.open_paren_idx + 1)];
	}

	sz positional_count = 0;
	List{String} used_names;
	used_names.tinit();

	if (args_text.len > 0)
	{
		int depth = 0;
		bool in_str = false;
		bool in_char = false;
		bool in_raw = false;
		sz arg_start = 0;

		for (sz i = 0; i < args_text.len; i++)
		{
			char c = args_text[i];
			if (in_raw)
			{
				if (c == '`') in_raw = false;
				continue;
			}
			if (in_str)
			{
				if (c == '\\' && i + 1 < args_text.len) { i++; continue; }
				if (c == '"') in_str = false;
				continue;
			}
			if (in_char)
			{
				if (c == '\\' && i + 1 < args_text.len) { i++; continue; }
				if (c == '\'') in_char = false;
				continue;
			}

			switch (c)
			{
				case '`': in_raw = true;
				case '"': in_str = true;
				case '\'': in_char = true;
				case '(':
				case '[':
				case '{':
					depth++;
				case ')':
				case ']':
				case '}':
					if (depth > 0) depth--;
				case ',':
					if (depth == 0)
					{
						String completed_arg = args_text[arg_start : i - arg_start].trim();
						if (completed_arg.len > 0)
						{
							String named = extract_named_arg_identifier(completed_arg);
							if (named.len > 0)
							{
								used_names.push(named);
							}
							else
							{
								positional_count++;
							}
						}
						arg_start = i + 1;
					}
				default:
					break;
			}
		}
	}

	for (sz i = start_idx; i < params.len; i++)
	{
		sz param_pos_idx = i - start_idx;
		if (param_pos_idx < positional_count) continue;

		Node* p = params[i];
		if (!p || p.kind != VAR_DECL) continue;
		VarDecl* vd = p.as(VarDecl);
		String raw_name = vd.name ? vd.name.text : "";
		if (raw_name.len == 0 || vd.var_flags.is_variadic) continue;

		String pname = raw_name.strip_prefix("#").strip_prefix("$");

		bool already_used = false;
		foreach (u : used_names)
		{
			if (u == pname) { already_used = true; break; }
		}
		if (already_used) continue;

		if (fuzzy_match(pname, ctx.prefix))
		{
			String ptype = vd.type ? (cursor::spelling(vd.type, tmem) ?: "any") : "any";
			String sort_prefix = (param_pos_idx == (sz)target_info.active_param) ? "0002" : "0004";
			items.push(
			{
				.label = string::tformat("%s:", pname),
				.kind = FIELD,
				.detail = string::tformat("%s %s:", ptype, pname),
				.insertText = string::tformat("%s: ", pname),
				.filterText = pname,
				.sortText = string::tformat("%s_%s", sort_prefix, pname),
				.data = "property"
			}
			);
		}
	}
}

<*
 Path prefix a function, macro, global or fault declared in `decl_mod` needs at the
 completion site: none in its own module or when `@builtin`, else its last module
 segment, as c3c suggests.
*>
fn String module_qualifier(Context* ctx, Node* node, String decl_mod) @local
{
	if (decl_mod.len == 0 || decl_mod == ctx.caller_mod) return "";
	if (cursor::has_attribute(node, BUILTIN, null)) return "";
	sz start = (decl_mod.rindex_of("::") ?? -2) + 2;
	return string::tformat("%s::", decl_mod[start..]);
}

<*
 Visible modules by their last path segment, the shortest qualifier.
*>
fn void provide_modules(Context* ctx, List{CompletionItem}* items) @local
{
	if (ctx.access != NONE || !ctx.ws || !ctx.ws.ctx) return;
	HashSet{String} seen;
	seen.tinit();
	Location loc = { (int)ctx.position.line, (int)ctx.position.character };
	foreach (name : query::visible_modules(ctx.ws.ctx, ctx.sf, loc))
	{
		String segment = name[(name.rindex_of("::") ?? -2) + 2..];
		if (!fuzzy_match(segment, ctx.prefix) || !seen.add(segment)) continue;
		items.push({
			.label = segment,
			.kind = MODULE,
			.detail = name,
			.insertText = segment,
			.filterText = segment,
			.sortText = string::tformat("0009_%s", segment),
			.data = string::tformat("module:%s", name)
		});
	}
}

<*
 After `base::`, the next path segment of each visible module whose path
 holds `base` as whole segments: `lib::|` offers `mathx` of `lib::mathx`.
 Returns whether `base` names part of a visible module path.
*>
fn bool provide_submodules(Context* ctx, List{CompletionItem}* items, String base) @local
{
	if (!ctx.ws || !ctx.ws.ctx || base.len == 0) return false;
	bool matched;
	HashSet{String} seen;
	seen.tinit();
	Location loc = { (int)ctx.position.line, (int)ctx.position.character };
	String key = string::tformat("::%s::", base);
	foreach (name : query::visible_modules(ctx.ws.ctx, ctx.sf, loc))
	{
		// Delimited on both sides so that `key` matches whole segments only.
		String path = string::tformat("::%s::", name);
		sz at = path.index_of(key) ?? -1;
		if (at < 0) continue;
		matched = true;
		String rest = path[at + key.len..];
		if (rest.len == 0) continue;
		String segment = rest[:rest.index_of("::") ?? rest.len];
		if (!fuzzy_match(segment, ctx.prefix) || !seen.add(segment)) continue;
		items.push({
			.label = segment,
			.kind = MODULE,
			.detail = path[2 : at + key.len + segment.len - 2],
			.insertText = segment,
			.filterText = segment,
			.sortText = string::tformat("0009_%s", segment),
			.data = string::tformat("module:%s", name)
		});
	}
	return matched;
}

fn void provide_global(Context* ctx, List{CompletionItem}* items)
{
	if (ctx.access != NONE || !ctx.ws || !ctx.ws.ctx) return;

	HashSet{String} seen_symbols;
	seen_symbols.tinit();

	foreach (item : *items)
	{
		seen_symbols.add(item.label);
	}

	if (ctx.ws.ctx.registry)
	{
		Registry* reg = ctx.ws.ctx.registry;

		reg.functions.@each(; qname, fn_info)
		{
			if (fn_info && fn_info.node && fn_info.node.kind == FN_DECL)
			{
				FnDecl* fndecl = fn_info.node.as(FnDecl);
				if (!fndecl.associated_type)
				{
					String fname = fndecl.name ? fndecl.name.text : "";
					if (fname.len > 0 && fuzzy_match(fname, ctx.prefix))
					{
						if (seen_symbols.add(fname))
						{
							add_symbol_completion(ctx, items, fname, fn_info.node, fn_info.mod, ctx.prefix, module_qualifier(ctx, fn_info.node, fn_info.mod));
						}
					}
				}
			}
		};

		reg.types.@each(; qname, ty_info)
		{
			if (ty_info && ty_info.node)
			{
				String tname = cursor::spelling(ty_info.node, tmem);
				if (tname.len > 0 && fuzzy_match(tname, ctx.prefix))
				{
					if (seen_symbols.add(tname))
					{
						add_symbol_completion(ctx, items, tname, ty_info.node, ty_info.mod, ctx.prefix);
					}
				}
			}
		};

		reg.macros.@each(; qname, mac_info)
		{
			if (mac_info && mac_info.node && mac_info.node.kind == MACRO_DECL)
			{
				MacroDecl* mac = mac_info.node.as(MacroDecl);
				if (!@ok(mac.associated_type.get()))
				{
					String mname = mac.name ? mac.name.text : "";
					if (mname.len > 0 && fuzzy_match(mname, ctx.prefix))
					{
						if (seen_symbols.add(mname))
						{
							add_symbol_completion(ctx, items, mname, mac_info.node, mac_info.mod, ctx.prefix, module_qualifier(ctx, mac_info.node, mac_info.mod));
						}
					}
				}
			}
		};
	}

	ctx.ws.ctx.files.@each(; file_path, sf)
	{
		if (sf)
		{
			foreach (stmt : sf.ast.statements)
			{
				if (stmt)
				{
					String stmt_mod = query::get_module_name_at_location(sf, stmt.range.start);
					String mod_ident = stmt_mod.len > 0 ? stmt_mod : "global";
					if (stmt.kind == ATTRDEF_DECL) continue;
					if (stmt.kind == FN_DECL && stmt.as(FnDecl).associated_type != null) continue;
					if (stmt.kind == MACRO_DECL && @ok(stmt.as(MacroDecl).associated_type.get())) continue;

					if (stmt.kind == FAULTDEF_DECL)
					{
						FaultdefDecl* fd = stmt.as(FaultdefDecl);
						foreach (fault_node : fd.faults)
						{
							if (!fault_node || fault_node.kind != FAULT_DECL) continue;
							FaultDecl* fdecl = fault_node.as(FaultDecl);
							String fname = fdecl.name ? fdecl.name.text : "";
							if (fname.len > 0 && fuzzy_match(fname, ctx.prefix))
							{
								if (seen_symbols.add(fname))
								{
									add_symbol_completion(ctx, items, fname, fault_node, mod_ident, ctx.prefix, module_qualifier(ctx, fault_node, stmt_mod));
								}
							}
						}
						continue;
					}
					if (stmt.kind == FAULT_DECL)
					{
						FaultDecl* fdecl = stmt.as(FaultDecl);
						String fname = fdecl.name ? fdecl.name.text : "";
						if (fname.len > 0 && fuzzy_match(fname, ctx.prefix))
						{
							if (seen_symbols.add(fname))
							{
								add_symbol_completion(ctx, items, fname, stmt, mod_ident, ctx.prefix, module_qualifier(ctx, stmt, stmt_mod));
							}
						}
						continue;
					}


					String sname = cursor::spelling(stmt, tmem);
					if (sname.len > 0 && fuzzy_match(sname, ctx.prefix))
					{
						if (seen_symbols.add(sname))
						{
							bool needs_path = stmt.kind == FN_DECL || stmt.kind == MACRO_DECL || stmt.kind == VAR_DECL;
							add_symbol_completion(ctx, items, sname, stmt, mod_ident, ctx.prefix, needs_path ? module_qualifier(ctx, stmt, stmt_mod) : "");
						}
					}
				}
			}
		}
	};
}

fn void provide_global_types_only(Context* ctx, List{CompletionItem}* items)
{
	if (ctx.access != NONE || !ctx.ws || !ctx.ws.ctx) return;

	HashSet{String} seen_symbols;
	seen_symbols.tinit();

	foreach (item : *items)
	{
		seen_symbols.add(item.label);
	}

	if (ctx.ws.ctx.registry)
	{
		Registry* reg = ctx.ws.ctx.registry;
		reg.types.@each(; qname, ty_info)
		{
			if (ty_info && ty_info.node)
			{
				String tname = cursor::spelling(ty_info.node, tmem);
				if (tname.len > 0 && fuzzy_match(tname, ctx.prefix))
				{
					if (seen_symbols.add(tname))
					{
						add_symbol_completion(ctx, items, tname, ty_info.node, ty_info.mod, ctx.prefix);
					}
				}
			}
		};
	}

	ctx.ws.ctx.files.@each(; file_path, sf)
	{
		if (sf)
		{
			String file_mod = query::get_source_file_module_name(sf);
			String mod_ident = file_mod.len > 0 ? file_mod : "global";
			foreach (stmt : sf.ast.statements)
			{
				if (stmt)
				{
					switch (stmt.kind)
					{
						case STRUCT_DECL:
						case ENUM_DECL:
						case TYPEDEF_DECL:
						case ALIAS_DECL:
						case INTERFACE_DECL:
							{
								String sname = cursor::spelling(stmt, tmem);
								if (sname.len > 0 && fuzzy_match(sname, ctx.prefix))
								{
									if (seen_symbols.add(sname))
									{
										add_symbol_completion(ctx, items, sname, stmt, mod_ident, ctx.prefix);
									}
								}
							}
						default:
							break;
					}
				}
			}
		}
	};
}

// ---------------------------------------------------------------------------
// Member Access & Initializers
// ---------------------------------------------------------------------------

<*
 Type of the expression `text` of `sf`, a view into its content, as the
 analyzer types the expression written there.
*>
fn String type_of_text(Context* ctx, SourceFile* sf, String text) @local
{
	if (!ctx.ws || !ctx.ws.ctx || !text.len) return "";
	Range range = analysis::range_of(sf.content, text);
	Node* expr = parser::parse_expression(ctx.ws.ctx, sf, range);
	return expr ? query::type_of(ctx.ws.ctx, sf, expr, range.start) : "";
}

<*
 Declared type of the parameter taking the argument at the cursor of the
 call `info` describes, or empty.
*>
fn String active_param_type(Context* ctx, SourceFile* sf, CallTargetInfo info) @local
{
	if (!ctx.ws || !ctx.ws.ctx) return "";
	CallTarget target = analysis::call_target_of(ctx.ws.ctx, sf, info);
	sz index = info.active_param + target.first_param;
	if (index >= target.params.len) return "";
	Node* param = target.params[index];
	if (!param || param.kind != VAR_DECL || !param.as(VarDecl).type) return "";
	Node* type = param.as(VarDecl).type;
	return (cursor::raw_type_identifier(type) ?? cursor::spelling(type, tmem)).trim_right("*& \t");
}

<*
 Type expected at the cursor inside an initializer list, or "". Queried at
 the token before the cursor: a list or `.a =` missing its value ends there.
*>
fn String initializer_slot_type(Context* ctx, SourceFile* sf) @local
{
	if (!ctx.ws || !ctx.ws.ctx || !sf) return "";
	String before = sf.content[:ctx.offset].trim_right();
	return query::initializer_slot_type(ctx.ws.ctx, sf, core::location_at(sf.content, before.len));
}

<*
 Struct, union or bitstruct whose fields the designators at the cursor
 name, or "".
*>
fn String designated_struct_at(Context* ctx, SourceFile* sf) @local
{
	String type = initializer_slot_type(ctx, sf);
	if (type.len == 0) return "";
	Node* type_node = query::find_type_node_in_context(ctx.ws.ctx, sf, type, ctx.loc);
	return type_node && type_node.kind == STRUCT_DECL ? type : "";
}

fn void detect_access_context(Context* ctx, SourceFile* sf)
{
	ctx.access = NONE;
	ctx.base_identifier = "";
	ctx.missing_second_colon = false;
	ctx.is_designated_initializer = false;
	ctx.designated_has_dot = false;

	if (!sf || ctx.offset == 0 || ctx.offset > sf.content.len) return;

	String text = sf.content[:ctx.offset];
	sz cursor_idx = text.len;

	while (cursor_idx > 0)
	{
		char c = text[cursor_idx - 1];
		if (!c.is_alnum() && c != '_' && c != '@' && c != '#' && c != '$') break;
		cursor_idx--;
	}

	while (cursor_idx > 0 && (text[cursor_idx - 1] == ' ' || text[cursor_idx - 1] == '\t'))
	{
		cursor_idx--;
	}

	String text_before = text[:cursor_idx];

	if (text_before.ends_with("::"))
	{
		ctx.access = STATIC;
		ctx.missing_second_colon = false;
		cursor_idx -= 2;
	}
	else if (text_before.ends_with("."))
	{
		ctx.access = INSTANCE;
		cursor_idx -= 1;
	}
	else if (text_before.ends_with(":"))
	{
		if (cursor_idx < text.len && (text[cursor_idx] == ' ' || text[cursor_idx] == '\t'))
		{
			ctx.access = NONE;
			return;
		}

		if (cursor_idx >= 2 && (text[cursor_idx - 2] == ' ' || text[cursor_idx - 2] == '\t'))
		{
			ctx.access = NONE;
			return;
		}

		sz line_start = cursor_idx;
		while (line_start > 0 && text[line_start - 1] != '\n') line_start--;
		String line_prefix = text[line_start : cursor_idx - line_start];
		String line_trim = line_prefix.trim_left();

		if (line_trim.starts_with("case") || line_trim.starts_with("$case") ||
		    line_trim.starts_with("default") || line_trim.starts_with("$default") ||
		    line_prefix.contains("?") ||
		    (cursor_idx >= 2 && text[cursor_idx - 2] == ')'))
		{
			ctx.access = NONE;
			return;
		}

		// A single `:` is a half-typed `::` only right after it and after a
		// module or type: `buffer[read:len]` slices, `name: value` names.
		sz word_start = cursor_idx - 1;
		while (word_start > 0 && lexer::is_ident(text[word_start - 1])) word_start--;
		String word = text[word_start : cursor_idx - 1 - word_start];
		Location loc = { (int)ctx.position.line, (int)ctx.position.character };
		bool names_module = false;
		if (ctx.ws && ctx.ws.ctx && word.len)
		{
			foreach (name : query::visible_modules(ctx.ws.ctx, sf, loc))
			{
				if (name == word || name.ends_with(string::tformat("::%s", word))) names_module = true;
			}
		}
		bool names_type = ctx.ws && ctx.ws.ctx && word.len && (constants::is_primitive(word) || query::find_type_node_in_context(ctx.ws.ctx, sf, word, ctx.loc));
		if (ctx.prefix.len > 0 || (!names_module && !names_type))
		{
			ctx.access = NONE;
			return;
		}

		ctx.access = STATIC;
		ctx.missing_second_colon = true;
		cursor_idx -= 1;
	}
	else
	{
		sz p = cursor_idx;
		while (p > 0 && text[p - 1].is_space()) p--;
		if (p > 0 && (text[p - 1] == '{' || text[p - 1] == ','))
		{
			String struct_type = designated_struct_at(ctx, sf);
			if (struct_type.len > 0)
			{
				ctx.access = INSTANCE;
				ctx.base_identifier = struct_type;
				ctx.is_designated_initializer = true;
				ctx.designated_has_dot = false;
				return;
			}
		}
		return;
	}

	while (cursor_idx > 0 && text[cursor_idx - 1].is_space()) cursor_idx--;

	sz base_end = cursor_idx;
	sz base_start = utils::scan_base_expression_start(text, base_end);

	if (base_end > base_start)
	{
		ctx.base_identifier = text[base_start : base_end - base_start];
	}
	else
	{
		String struct_type = designated_struct_at(ctx, sf);
		if (struct_type.len > 0)
		{
			ctx.access = INSTANCE;
			ctx.base_identifier = struct_type;
			ctx.is_designated_initializer = true;
			ctx.designated_has_dot = true;
			return;
		}
		ctx.access = NONE;
		ctx.missing_second_colon = false;
		// A `.` after `{` or `,` starts a designator: only fields fit there.
		if (base_end > 0 && (text[base_end - 1] == '{' || text[base_end - 1] == ',')) ctx.scope = NONE;
	}
}

fn void inject_vector_swizzles(List{CompletionItem}* items, String prefix)
{
	const String[*] COMPS = {
		"x", "y", "z", "w", "r", "g", "b", "a", "u", "v",
		"xy", "yx", "xx", "yy", "xz", "yz", "zx", "zy", "zz",
		"xyz", "xzy", "yxz", "yzx", "zxy", "zyx",
		"xyzw", "rgba"
	};
	foreach (c : COMPS)
	{
		if (prefix.len == 0 || c.starts_with(prefix))
		{
			items.push(
			{
				.label = c,
				.kind = FIELD,
				.detail = "swizzle",
				.insertText = c,
				.filterText = c,
				.sortText = string::tformat("0001_%s", c),
				.data = "property"
			}
			);
		}
	}
}

<*
 Methods an interface declares, with those of the interfaces it extends.
*>
fn void provide_interface_methods(Context* ctx, List{CompletionItem}* items, Node* iface, HashSet{String}* seen_methods, int depth = 0) @local
{
	if (depth >= query::MAX_ALIAS_DEPTH) return;
	InterfaceDecl* id = iface.as(InterfaceDecl);
	String owner = id.name ? id.name.text : "";
	foreach (m : id.methods)
	{
		if (!m || m.kind != FN_DECL || !m.as(FnDecl).name) continue;
		String name = m.as(FnDecl).name.text;
		if (fuzzy_match(name, ctx.prefix) && seen_methods.add(name)) add_symbol_completion(ctx, items, name, m, owner, ctx.prefix);
	}
	foreach (parent : id.interfaces)
	{
		Node* parent_node = query::find_type_node_in_context(ctx.ws.ctx, ctx.sf, cursor::raw_type_identifier(parent) ?? "", ctx.loc);
		if (parent_node && parent_node.kind == INTERFACE_DECL) provide_interface_methods(ctx, items, parent_node, seen_methods, depth + 1);
	}
}

fn void provide_methods_for_type(Context* ctx, List{CompletionItem}* items, String type_name, HashSet{String}* seen_methods)
{
	if (!ctx.ws || !ctx.ws.ctx || type_name.len == 0) return;

	String clean_type = type_name.trim_right("*& \t");
	if (try brace_idx = clean_type.index_of_char('{'))
	{
		clean_type = clean_type[:brace_idx].trim();
	}
	clean_type = clean_type.trim_right("*& \t");

	Registry* reg = ctx.ws.ctx.registry;
	if (reg)
	{
		reg.functions.@each(; qname, fn_info)
		{
			FunctionInfo* curr = fn_info;
			while (curr != null)
			{
				if (curr.node && curr.node.kind == FN_DECL)
				{
					FnDecl* fndecl = curr.node.as(FnDecl);
					if (fndecl.associated_type && query::is_matching_associated_type(fndecl.associated_type, clean_type, type_name))
					{
						Location loc = { (int)ctx.position.line, (int)ctx.position.character };
						if (query::is_symbol_accessible_at(ctx.ws.ctx, ctx.sf, loc, curr.node, curr.mod))
						{
							String mname = fndecl.name ? fndecl.name.text : "";
							if (mname.len > 0 && fuzzy_match(mname, ctx.prefix))
							{
								if (seen_methods.add(mname))
								{
									add_symbol_completion(ctx, items, mname, curr.node, clean_type, ctx.prefix);
								}
							}
						}
					}
				}
				curr = curr.next;
			}
		};

		reg.macros.@each(; qname, mac_info)
		{
			MacroInfo* curr = mac_info;
			while (curr != null)
			{
				if (curr.node && curr.node.kind == MACRO_DECL)
				{
					MacroDecl* mac = curr.node.as(MacroDecl);
					if (try assoc_node = mac.associated_type.get())
					{
						if (query::is_matching_associated_type(assoc_node, clean_type, type_name))
						{
							Location loc = { (int)ctx.position.line, (int)ctx.position.character };
							if (query::is_symbol_accessible_at(ctx.ws.ctx, ctx.sf, loc, curr.node, curr.mod))
							{
								String mname = mac.name ? mac.name.text : "";
								if (mname.len > 0 && fuzzy_match(mname, ctx.prefix))
								{
									if (seen_methods.add(mname))
									{
										add_symbol_completion(ctx, items, mname, curr.node, clean_type, ctx.prefix);
									}
								}
							}
						}
					}
				}
				curr = curr.next;
			}
		};
	}

	Node* type_node = query::find_type_node_in_context(ctx.ws.ctx, ctx.sf, clean_type, ctx.loc);
	if (type_node)
	{
		switch (type_node.kind)
		{
			case TYPEDEF_DECL:
				{
					TypedefDecl* td = type_node.as(TypedefDecl);
					if (td.is_inline && td.base_type)
					{
						String base_type_str = cursor::raw_type_identifier(td.base_type) ?? cursor::spelling(td.base_type, tmem);
						if (base_type_str.len > 0 && base_type_str != clean_type)
						{
							provide_methods_for_type(ctx, items, base_type_str, seen_methods);
						}
					}
				}
			case ALIAS_DECL:
				{
					AliasDecl* ad = type_node.as(AliasDecl);
					if (ad.target)
					{
						if (ad.target.kind == TERNARY_EXPR)
						{
							TernaryExpr* ter = ad.target.as(TernaryExpr);
							if (ter.then_expr)
							{
								String t_type = cursor::raw_type_identifier(ter.then_expr) ?? cursor::spelling(ter.then_expr, tmem);
								t_type = t_type.trim_right("*& \t");
								if (t_type.len > 0 && t_type != clean_type)
								{
									provide_methods_for_type(ctx, items, t_type, seen_methods);
								}
							}
							if (ter.else_expr)
							{
								String e_type = cursor::raw_type_identifier(ter.else_expr) ?? cursor::spelling(ter.else_expr, tmem);
								e_type = e_type.trim_right("*& \t");
								if (e_type.len > 0 && e_type != clean_type)
								{
									provide_methods_for_type(ctx, items, e_type, seen_methods);
								}
							}
						}
						else
						{
							String target_type = cursor::raw_type_identifier(ad.target) ?? cursor::spelling(ad.target, tmem);
							target_type = target_type.trim_right("*& \t");
							if (target_type.len > 0 && target_type != clean_type)
							{
								provide_methods_for_type(ctx, items, target_type, seen_methods);
							}
						}
					}
				}
			case STRUCT_DECL:
				{
					StructDecl* sd = type_node.as(StructDecl);
					foreach (field : sd.fields)
					{
						if (!field || field.kind != VAR_DECL) continue;
						VarDecl* vd = field.as(VarDecl);
						if (vd.var_flags.is_inline && vd.type)
						{
							String sub_type = cursor::raw_type_identifier(vd.type) ?? "";
							if (sub_type.len > 0 && sub_type != clean_type)
							{
								provide_methods_for_type(ctx, items, sub_type, seen_methods);
							}
						}
					}
					foreach (inter : sd.interfaces)
					{
						String inter_type = cursor::raw_type_identifier(inter) ?? "";
						if (inter_type.len > 0 && inter_type != clean_type)
						{
							provide_methods_for_type(ctx, items, inter_type, seen_methods);
						}
					}
				}
			default:
				break;
		}
	}
}

fn void provide_enum_variants(List{CompletionItem}* items, Node* enum_node, String type_name, String prefix, bool missing_second_colon = false)
{
	if (!enum_node || enum_node.kind != ENUM_DECL) return;
	EnumDecl* enum_decl = enum_node.as(EnumDecl);

	foreach (variant : enum_decl.variants)
	{
		if (!variant || variant.kind != VAR_DECL) continue;
		VarDecl* var_decl = variant.as(VarDecl);
		String vname = var_decl.name ? var_decl.name.text : "";
		if (vname.len > 0 && fuzzy_match(vname, prefix))
		{
			String insert_str = missing_second_colon ? string::tformat(":%s", vname) : vname;
			items.push(
			{
				.label = vname,
				.kind = ENUMMEMBER,
				.detail = string::tformat("enum %s", type_name),
				.insertText = insert_str,
				.filterText = vname,
				.sortText = string::tformat("0000_%s", vname),
				.data = string::tformat("enum_variant:%s:%s", type_name, vname)
			}
			);
		}
	}
}

<*
 Built-in properties of values of type `type_name`, such as `len` of a slice.
*>
fn void provide_value_properties(Context* ctx, List{CompletionItem}* items, String type_name) @local
{
	foreach (property : ValueProperty::values)
	{
		if (ctx.prefix.len && !property.name.starts_with(ctx.prefix)) continue;
		String type = query::value_property_type(ctx.ws.ctx, ctx.sf, type_name, property);
		if (!type.len) continue;
		items.push({
			.label = property.name,
			.kind = PROPERTY,
			.detail = type,
			.documentation = { .kind = MARKDOWN, .value = property.doc },
			.insertText = property.name,
			.insertTextFormat = PLAIN_TEXT,
			.filterText = property.name,
			.sortText = string::tformat("0001_%s", property.name),
			.data = "property"
		});
	}
}

fn void provide_enum_associated_params(List{CompletionItem}* items, Node* enum_node, String type_name, String prefix)
{
	if (!enum_node || enum_node.kind != ENUM_DECL) return;
	EnumDecl* enum_decl = enum_node.as(EnumDecl);

	foreach (param : enum_decl.assoc_params)
	{
		if (!param || param.kind != VAR_DECL) continue;
		VarDecl* vd = param.as(VarDecl);
		String pname = vd.name ? vd.name.text : "";
		if (pname.len > 0 && fuzzy_match(pname, prefix))
		{
			String ptype = vd.type ? (cursor::raw_type_identifier(vd.type) ?? "") : "";
			items.push(
			{
				.label = pname,
				.kind = PROPERTY,
				.detail = ptype.len > 0 ? string::tformat("%s", ptype) : string::tformat("associated property of %s", type_name),
				.insertText = pname,
				.filterText = pname,
				.sortText = string::tformat("0001_%s", pname),
				.data = string::tformat("enum_assoc:%s:%s", type_name, pname)
			}
			);
		}
	}
}

fn void collect_already_set_fields(String text, sz open_brace_idx, sz cursor_offset, sz prefix_len, HashSet{String}* out_set) @local
{
	int brace_depth = 0;
	int paren_depth = 0;
	int bracket_depth = 0;
	bool in_str = false;
	bool in_char = false;
	bool in_raw = false;

	sz limit = cursor_offset > prefix_len ? cursor_offset - prefix_len : cursor_offset;

	for (sz i = open_brace_idx + 1; i < limit && i < text.len; i++)
	{
		char c = text[i];
		if (c == '`') { in_raw = !in_raw; continue; }
		if (in_raw) continue;
		if (c == '"' && (i == 0 || text[i - 1] != '\\')) { in_str = !in_str; continue; }
		if (in_str) continue;
		if (c == '\'' && (i == 0 || text[i - 1] != '\\')) { in_char = !in_char; continue; }
		if (in_char) continue;

		switch (c)
		{
			case '{': brace_depth++;
			case '}': if (brace_depth > 0) brace_depth--;
			case '(': paren_depth++;
			case ')': if (paren_depth > 0) paren_depth--;
			case '[': bracket_depth++;
			case ']': if (bracket_depth > 0) bracket_depth--;
			case '.':
				if (brace_depth == 0 && paren_depth == 0 && bracket_depth == 0)
				{
					sz start = i + 1;
					sz end = start;
					while (end < text.len && lexer::is_ident(text[end])) end++;
					if (end > start && end <= limit)
					{
						sz next_p = end;
						while (next_p < text.len && (text[next_p] == ' ' || text[next_p] == '\t')) next_p++;
						if (next_p < text.len && text[next_p] == '.')
						{
							continue;
						}

						String field_name = text[start : end - start];
						out_set.add(field_name);
						i = end - 1;
					}
				}
			default: break;
		}
	}
}

fn void collect_struct_fields_recursive(Context* ctx, List{CompletionItem}* items, Node* struct_node, String type_name, HashSet{String}* seen_fields)
{
	if (!struct_node || struct_node.kind != STRUCT_DECL) return;

	StructDecl* sd = struct_node.as(StructDecl);
	foreach (field : sd.fields)
	{
		if (!field) continue;
		if (field.kind == VAR_DECL)
		{
			VarDecl* fdecl = field.as(VarDecl);
			while (fdecl != null)
			{
				String fname = fdecl.name ? fdecl.name.text : "";
				if (fname.len > 0 && fuzzy_match(fname, ctx.prefix))
				{
					if (seen_fields.add(fname))
					{
						String ftype = cursor::spelling(fdecl.type, tmem);
						String insert_str = fname;
						InsertTextFormat format = PLAIN_TEXT;
						if (ctx.is_designated_initializer)
						{
							if (ctx.designated_has_dot)
							{
								insert_str = string::tformat("%s = $1", fname);
							}
							else
							{
								insert_str = string::tformat(".%s = $1", fname);
							}
							format = SNIPPET;
						}
						items.push(
						{
							.label = fname,
							.kind = FIELD,
							.detail = ftype,
							.insertText = insert_str,
							.insertTextFormat = format,
							.filterText = fname,
							.sortText = string::tformat("0001_%s", fname),
							.data = string::tformat("field:%s:%s", type_name, fname)
						}
						);
					}
				}
				if (fdecl.var_flags.is_inline && fdecl.type)
				{
					String sub_type = cursor::raw_type_identifier(fdecl.type) ?? cursor::spelling(fdecl.type, tmem);
					sub_type = sub_type.trim_right("*& \t");
					if (sub_type.len > 0)
					{
						Node* sub_node = query::find_type_node_in_context(ctx.ws.ctx, ctx.sf, sub_type, ctx.loc);
						if (!sub_node && ctx.ws)
						{
							List{SymbolEntry} syms = ctx.ws.find_symbol_by_name(sub_type, ctx.sf);
							if (syms.len() > 0 && syms.get(0).node) sub_node = syms.get(0).node;
						}
						if (sub_node && sub_node.kind == STRUCT_DECL)
						{
							collect_struct_fields_recursive(ctx, items, sub_node, sub_type, seen_fields);
						}
					}
				}
				fdecl = fdecl.next ? fdecl.next.as(VarDecl) : null;
			}
		}
		else if (field.kind == STRUCT_DECL)
		{
			StructDecl* sub = field.as(StructDecl);
			if (sub.name != null)
			{
				String sname = sub.name.text;
				if (sname.len > 0 && fuzzy_match(sname, ctx.prefix) && seen_fields.add(sname))
				{
					String kind_str = sub.is_union ? "union" : (sub.is_bitstruct ? "bitstruct" : "struct");
					String insert_str = sname;
					InsertTextFormat format = PLAIN_TEXT;
					if (ctx.is_designated_initializer)
					{
						if (ctx.designated_has_dot)
						{
							insert_str = string::tformat("%s = $1", sname);
						}
						else
						{
							insert_str = string::tformat(".%s = $1", sname);
						}
						format = SNIPPET;
					}
					items.push(
					{
						.label = sname,
						.kind = FIELD,
						.detail = string::tformat("%s %s", kind_str, sname),
						.insertText = insert_str,
						.insertTextFormat = format,
						.filterText = sname,
						.sortText = string::tformat("0001_%s", sname),
						.data = string::tformat("field:%s:%s", type_name, sname)
					}
					);
				}
			}
			else
			{
				collect_struct_fields_recursive(ctx, items, field, type_name, seen_fields);
			}
		}
	}
}

macro void @add_prop(items, String label, CompletionItemKind kind, String detail, String doc_text, bool missing_colon)
{
	String ins = missing_colon ? string::tformat(":%s", label) : label;
	items.push(
	{
		.label = label,
		.kind = kind,
		.detail = detail,
		.documentation = {
			.value = doc_text,
			.kind = MARKDOWN
		},
		.insertText = ins,
		.filterText = label,
		.sortText = string::tformat("0001_%s", label),
		.data = "property"
	}
	);
}

fn void inject_type_properties(List{CompletionItem}* items, NodeKind type_kind, String type_name = "", bool missing_second_colon = false)
{
	const constants::TypeProperty[*] COMMON_PROPS = {
		ALIGNMENT, KIND, NAME, QNAME, CNAME, SIZE, TYPEID, METHODS,
		HAS_EQUALS, IS_ORDERED, INNER, GENERIC_ARGS, GENERIC_QNAME, IS_GENERIC
	};
	foreach (p : COMMON_PROPS)
	{
		CompletionItemKind k = (p == IS_GENERIC) ? METHOD : PROPERTY;
		@add_prop(items, p.name, k, p.type_desc, p.doc, missing_second_colon);
	}

	bool is_float = false;
	bool is_int = false;
	if (try pt = constants::PrimitiveType::lookup_field(name, type_name))
	{
		is_float = pt.is_float();
		is_int = pt.is_int();
	}

	if (is_float || is_int || type_kind == VAR_DECL)
	{
		String t_label = type_name.len > 0 ? type_name : "any";
		@add_prop(items, constants::TypeProperty.MAX.name, PROPERTY, t_label, constants::TypeProperty.MAX.doc, missing_second_colon);
		@add_prop(items, constants::TypeProperty.MIN.name, PROPERTY, t_label, constants::TypeProperty.MIN.doc, missing_second_colon);
	}

	if (is_float)
	{
		@add_prop(items, constants::TypeProperty.NAN.name, PROPERTY, type_name, constants::TypeProperty.NAN.doc, missing_second_colon);
		@add_prop(items, constants::TypeProperty.INF.name, PROPERTY, type_name, constants::TypeProperty.INF.doc, missing_second_colon);
	}

	switch (type_kind)
	{
		case STRUCT_DECL:
			@add_prop(items, constants::TypeProperty.MEMBERS.name, PROPERTY, constants::TypeProperty.MEMBERS.type_desc, constants::TypeProperty.MEMBERS.doc, missing_second_colon);
			@add_prop(items, constants::TypeProperty.GET_TAG.name, METHOD, constants::TypeProperty.GET_TAG.type_desc, constants::TypeProperty.GET_TAG.doc, missing_second_colon);
			@add_prop(items, constants::TypeProperty.HAS_TAG.name, METHOD, constants::TypeProperty.HAS_TAG.type_desc, constants::TypeProperty.HAS_TAG.doc, missing_second_colon);
			@add_prop(items, constants::TypeProperty.IS_SUBSTRUCT.name, PROPERTY, constants::TypeProperty.IS_SUBSTRUCT.type_desc, constants::TypeProperty.IS_SUBSTRUCT.doc, missing_second_colon);
			@add_prop(items, constants::TypeProperty.PARENT.name, PROPERTY, constants::TypeProperty.PARENT.type_desc, constants::TypeProperty.PARENT.doc, missing_second_colon);
		case ENUM_DECL:
			@add_prop(items, constants::TypeProperty.VALUES.name, PROPERTY, constants::TypeProperty.VALUES.type_desc, constants::TypeProperty.VALUES.doc, missing_second_colon);
			@add_prop(items, constants::TypeProperty.LEN.name, PROPERTY, constants::TypeProperty.LEN.type_desc, constants::TypeProperty.LEN.doc, missing_second_colon);
			@add_prop(items, constants::TypeProperty.NAMES.name, PROPERTY, constants::TypeProperty.NAMES.type_desc, constants::TypeProperty.NAMES.doc, missing_second_colon);
			@add_prop(items, constants::TypeProperty.MEMBERS.name, PROPERTY, constants::TypeProperty.MEMBERS.type_desc, constants::TypeProperty.MEMBERS.doc, missing_second_colon);
			@add_prop(items, constants::TypeProperty.FROM_ORDINAL.name, METHOD, constants::TypeProperty.FROM_ORDINAL.type_desc, constants::TypeProperty.FROM_ORDINAL.doc, missing_second_colon);
			@add_prop(items, constants::TypeProperty.LOOKUP_FIELD.name, METHOD, constants::TypeProperty.LOOKUP_FIELD.type_desc, constants::TypeProperty.LOOKUP_FIELD.doc, missing_second_colon);
		case FN_DECL:
			@add_prop(items, constants::TypeProperty.PARAMS.name, PROPERTY, constants::TypeProperty.PARAMS.type_desc, constants::TypeProperty.PARAMS.doc, missing_second_colon);
			@add_prop(items, constants::TypeProperty.RETURNS.name, PROPERTY, constants::TypeProperty.RETURNS.type_desc, constants::TypeProperty.RETURNS.doc, missing_second_colon);
			@add_prop(items, constants::TypeProperty.PARAM_STRUCT.name, PROPERTY, constants::TypeProperty.PARAM_STRUCT.type_desc, constants::TypeProperty.PARAM_STRUCT.doc, missing_second_colon);
		default:
			break;
	}
}

fn void inject_reflect_properties(List{CompletionItem}* items, String prefix = "")
{
	foreach (p : constants::ReflectProperty::values)
	{
		if (prefix.len == 0 || p.name.starts_with(prefix))
		{
			CompletionItemKind k = (p == GET_TAG || p == HAS_TAG) ? METHOD : PROPERTY;
			items.push(
			{
				.label = p.name,
				.kind = k,
				.detail = p.type_desc,
				.documentation = {
					.value = p.doc,
					.kind = MARKDOWN
				},
				.insertText = p.name,
				.filterText = p.name,
				.sortText = string::tformat("0001_%s", p.name),
				.data = "property"
			}
			);
		}
	}
}

fn bool provide_member_access(Context* ctx, List{CompletionItem}* items)
{
	if (ctx.access == NONE || ctx.base_identifier.len == 0) return false;

	if (ctx.base_identifier == "$reflect" || ctx.base_identifier.starts_with("$reflect"))
	{
		if (ctx.access == INSTANCE)
		{
			inject_reflect_properties(items, ctx.prefix);
			return true;
		}
	}

	String base_id = ctx.base_identifier;

	switch (ctx.access)
	{
		case STATIC:
			{
				Location loc = { .line = (int)ctx.position.line, .column = (int)ctx.position.character };

				bool is_type_name = (base_id.len > 0 && base_id[0] >= 'A' && base_id[0] <= 'Z') ||
					constants::is_primitive(base_id) ||
					base_id.contains("{") ||
					base_id.starts_with("$");

				if (!is_type_name && ctx.ws && ctx.ws.ctx)
				{
					bool is_module_path = provide_submodules(ctx, items, base_id);
					// Nothing tells yet which module the prefix means, so every one it can name is offered.
					List{Module*} mods;
					mods.tinit();
					query::resolve_module_for_prefix(ctx.ws.ctx, ctx.sf, loc, base_id, all: &mods);
					if (!mods.len())
					{
						if (Module* found = analysis::find_module_by_identifier(ctx.ws, "", base_id)) mods.push(found);
					}
					foreach (mod : mods)
					{
						foreach (node : mod.nodes)
						{
							if (!node || node.kind == ERROR) continue;
							if (node.kind == FN_DECL && node.as(FnDecl).associated_type != null) continue;
							if (node.kind == MACRO_DECL && @ok(node.as(MacroDecl).associated_type.get())) continue;

							if (node.kind == FAULTDEF_DECL)
							{
								FaultdefDecl* fd = node.as(FaultdefDecl);
								foreach (fault_node : fd.faults)
								{
									if (!fault_node || fault_node.kind != FAULT_DECL) continue;
									if (!query::is_symbol_accessible_at(ctx.ws.ctx, ctx.sf, loc, fault_node, mod.name)) continue;

									FaultDecl* fdecl = fault_node.as(FaultDecl);
									String fname = fdecl.name ? fdecl.name.text : "";
									if (fname.len > 0 && fuzzy_match(fname, ctx.prefix))
									{
										add_symbol_completion(ctx, items, fname, fault_node, base_id, ctx.prefix);
									}
								}
								continue;
							}

							if (!query::is_symbol_accessible_at(ctx.ws.ctx, ctx.sf, loc, node, mod.name)) continue;

							String sym_name = cursor::spelling(node, tmem);
							if (sym_name.len == 0) continue;
							if (fuzzy_match(sym_name, ctx.prefix))
							{
								add_symbol_completion(ctx, items, sym_name, node, base_id, ctx.prefix);
							}
						}
					}
					if (mods.len() || is_module_path) return true;
				}

				// `$Type::` and a generic parameter's `Type::` stand for any type: any property fits.
				bool any_type = base_id.starts_with("$");
				foreach (param : query::generic_params_at(ctx.ws.ctx, ctx.sf, loc))
				{
					if (query::generic_param_name(param) == base_id) any_type = true;
				}
				if (any_type)
				{
					foreach (p : constants::TypeProperty::values)
					{
						@add_prop(items, p.name, p.type_desc.starts_with("fn") ? METHOD : PROPERTY, p.type_desc, p.doc, ctx.missing_second_colon);
					}
					return true;
				}

				// The base of `::` names a type, which need not be an expression.
				String type_name = type_of_text(ctx, ctx.sf, base_id) ?: base_id;
				String clean_type = type_name;
				if (try brace_idx = type_name.index_of_char('{'))
				{
					clean_type = type_name[:brace_idx].trim();
				}

				List{SymbolEntry} syms = ctx.ws.find_symbol_by_name(clean_type, ctx.sf);
				if (syms.len() > 0 && syms.get(0).node)
				{
					Node* sym_node = syms.get(0).node;
					inject_type_properties(items, sym_node.kind, type_name, ctx.missing_second_colon);
					return true;
				}

				if (constants::is_primitive(base_id))
				{
					inject_type_properties(items, NodeKind.VAR_DECL, type_name, ctx.missing_second_colon);
					return true;
				}

				return true;
			}

		case INSTANCE:
			{
				Location loc = { .line = (int)ctx.position.line, .column = (int)ctx.position.character };
				String type_name = ctx.is_designated_initializer ? base_id : type_of_text(ctx, ctx.sf, base_id);
				String clean_type = type_name;
				if (try brace_idx = type_name.index_of_char('{'))
				{
					clean_type = type_name[:brace_idx].trim();
				}

				if (clean_type.len == 0) return false;

				provide_value_properties(ctx, items, type_name);

				HashSet{String} seen_methods;
				seen_methods.tinit();

				Node* type_node = query::find_type_node_in_context(ctx.ws.ctx, ctx.sf, clean_type, ctx.loc);
				if (!type_node && ctx.ws)
				{
					List{SymbolEntry} syms = ctx.ws.find_symbol_by_name(clean_type, ctx.sf);
					if (syms.len() > 0 && syms.get(0).node)
					{
						type_node = syms.get(0).node;
					}
				}

				if (type_node && type_node.kind == ENUM_DECL)
				{
					bool is_type_access = false;
					if (base_id == clean_type || base_id.ends_with(string::tformat("::%s", clean_type)))
					{
						String dummy = "";
						if (!query::find_local_decl_in_file(ctx.sf, base_id, &dummy, ctx.ws ? ctx.ws.ctx : null, loc))
						{
							is_type_access = true;
						}
					}

					if (is_type_access)
					{
						provide_enum_variants(items, type_node, clean_type, ctx.prefix, false);
					}
					else
					{
						provide_enum_associated_params(items, type_node, clean_type, ctx.prefix);
					}
					provide_methods_for_type(ctx, items, clean_type, &seen_methods);
					return true;
				}

				if (query::is_vector_type(clean_type))
				{
					inject_vector_swizzles(items, ctx.prefix);
				}

				if (type_node && type_node.kind == INTERFACE_DECL) provide_interface_methods(ctx, items, type_node, &seen_methods);

				// Typedefs and aliases keep the fields of the struct they stand for; only an inline typedef keeps the methods.
				Node* fields_node = type_node;
				String fields_type = type_name;
				for (int depth = 0; depth < query::MAX_ALIAS_DEPTH && fields_node && (fields_node.kind == TYPEDEF_DECL || fields_node.kind == ALIAS_DECL); depth++)
				{
					fields_type = query::aliased_type(ctx.ws.ctx, ctx.sf, fields_type);
					fields_node = fields_type.len ? query::find_type_node_in_context(ctx.ws.ctx, ctx.sf, query::generic_base(fields_type), ctx.loc) : null;
				}

				if (fields_node && fields_node.kind == STRUCT_DECL)
				{
					HashSet{String} seen_fields;
					seen_fields.tinit();
					if (ctx.is_designated_initializer && ctx.sf)
					{
						sz open_brace = utils::find_enclosing_open_brace(ctx.sf.content, ctx.offset);
						if (open_brace != (sz)-1)
						{
							collect_already_set_fields(ctx.sf.content, open_brace, ctx.offset, ctx.prefix.len, &seen_fields);
						}
					}
					collect_struct_fields_recursive(ctx, items, fields_node, fields_type, &seen_fields);
				}

				if (!ctx.is_designated_initializer)
				{
					provide_methods_for_type(ctx, items, type_name, &seen_methods);
				}
				return true;
			}

		default:
			return false;
	}
}

// ---------------------------------------------------------------------------
// Context Classification
// ---------------------------------------------------------------------------

fn bool detect_attribute_context(Context* ctx, Location loc, AttributeTargetKind* out_target)
{
	if (!ctx || !ctx.sf || ctx.offset == 0 || ctx.offset > ctx.sf.content.len) return false;

	bool has_at_prefix = ctx.prefix.starts_with("@");
	bool has_at_char = !has_at_prefix && ctx.prefix.len == 0 && ctx.offset > 0 && ctx.sf.content[ctx.offset - 1] == '@';
	if (!has_at_prefix && !has_at_char) return false;

	sz at_pos = has_at_prefix ? (ctx.offset - ctx.prefix.len) : (ctx.offset - 1);

	sz stmt_start = at_pos;
	while (stmt_start > 0 && ctx.sf.content[stmt_start - 1] != '\n' && ctx.sf.content[stmt_start - 1] != ';' && ctx.sf.content[stmt_start - 1] != '{' && ctx.sf.content[stmt_start - 1] != '}')
	{
		stmt_start--;
	}

	String before_at = ctx.sf.content[stmt_start : at_pos - stmt_start].trim();
	if (before_at.contains("=>")) return false;

	if (try first_at = before_at.index_of_char('@'))
	{
		before_at = before_at[:first_at].trim();
	}

	String scan_word = before_at;
	if (scan_word.starts_with("extern ") || scan_word.starts_with("extern\t"))
	{
		scan_word = scan_word[7..].trim_left();
	}
	sz kw_end = 0;
	while (kw_end < scan_word.len && lexer::is_ident(scan_word[kw_end])) kw_end++;
	String first_kw = scan_word[:kw_end];

	switch (first_kw)
	{
		case "import":
			*out_target = IMPORT;
			return true;
		case "module":
			*out_target = MODULE;
			return true;
		case "attrmacro":
		case "attrdef":
			*out_target = ATTRDEF;
			return true;
		case "switch":
			*out_target = SWITCH;
			return true;
		case "fn":
		case "macro":
			*out_target = FUNCTION;
			return true;
		case "enum":
		case "constdef":
		case "constset":
			*out_target = ENUM;
			return true;
		default:
			if (constants::is_type_decl_keyword(first_kw))
			{
				*out_target = TYPE;
				return true;
			}
			break;
	}

	if (before_at.ends_with(")"))
	{
		int pdepth = 1;
		sz p = before_at.len - 1;
		while (p > 0 && pdepth > 0)
		{
			p--;
			if (before_at[p] == ')')
			{
				pdepth++;
			}
			else if (before_at[p] == '(')
			{
				pdepth--;
			}
		}
		if (pdepth == 0)
		{
			sz callee_end = p;
			while (callee_end > 0 && (before_at[callee_end - 1] == ' ' || before_at[callee_end - 1] == '\t')) callee_end--;
			sz callee_start = callee_end;
			while (callee_start > 0 && (lexer::is_ident(before_at[callee_start - 1]) || before_at[callee_start - 1] == ':')) callee_start--;
			String callee = before_at[callee_start : callee_end - callee_start].trim();
			// Only a call takes attributes after `)`; a cast, a group or a statement
			// head such as `if (x)` is followed by an expression or a statement.
			if (!callee.len || constants::is_keyword(callee)) return false;
			*out_target = CALL;
			return true;
		}
	}

	if (loc.line >= 0)
	{
		foreach (stmt : ctx.sf.ast.statements)
		{
			if (stmt && stmt.range.contains(loc))
			{
				switch (stmt.kind)
				{
					case STRUCT_DECL:
						*out_target = FIELD;
						return true;
					case ENUM_DECL:
						*out_target = ENUM_MEMBER;
						return true;
					case FN_DECL:
					case MACRO_DECL:
						{
							Node* body = (stmt.kind == FN_DECL) ? stmt.as(FnDecl).body : stmt.as(MacroDecl).body;
							if (!body || !body.range.contains(loc))
							{
								*out_target = FUNCTION;
								return true;
							}

							if (before_at.len > 0 && !before_at.ends_with("=") && !before_at.ends_with("{") && !before_at.ends_with(";"))
							{
								String[] words = before_at.tsplit(" ");
								if (words.len >= 2 || before_at.starts_with("var ") || before_at.starts_with("const ") || before_at.starts_with("tlocal ") || before_at.starts_with("static "))
								{
									*out_target = VARIABLE;
									return true;
								}
							}
							return false;
						}
					default:
						break;
				}
			}
		}
	}

	if (before_at.len > 0 && !before_at.ends_with("=") && !before_at.ends_with("{"))
	{
		*out_target = VARIABLE;
		return true;
	}

	if (before_at.len == 0)
	{
		bool inside_fn = false;
		if (loc.line >= 0)
		{
			foreach (stmt : ctx.sf.ast.statements)
			{
				if (stmt && stmt.range.contains(loc))
				{
					if (stmt.kind == FN_DECL && stmt.as(FnDecl).body && stmt.as(FnDecl).body.range.contains(loc))
					{
						inside_fn = true;
						break;
					}
					if (stmt.kind == MACRO_DECL && stmt.as(MacroDecl).body && stmt.as(MacroDecl).body.range.contains(loc))
					{
						inside_fn = true;
						break;
					}
				}
			}
		}
		if (!inside_fn)
		{
			return false;
		}
	}

	return false;
}

<*
 Names of the values handled by the cases of `switch_node` other than the
 one at `loc`: `RED` for `case RED:` and `case Color.RED:`.
*>
fn void collect_already_handled_cases(Node* switch_node, Location loc, HashSet{String}* out_set) @local
{
	NodeArray cases = switch_node.kind == SWITCH_STMT ? switch_node.as(SwitchStmt).cases : switch_node.as(CtSwitchStmt).cases;
	foreach (c : cases)
	{
		if (!c || c.kind != CASE_STMT || c.range.contains(loc)) continue;
		Node* value = c.as(CaseStmt).expr;
		if (value && value.kind == ACCESS_EXPR) value = value.as(AccessExpr).member;
		if (value && value.kind == IDENT_EXPR && value.as(IdentExpr).ident) out_set.add(value.as(IdentExpr).ident.text);
	}
}

fn ScopeKind detect_completion_scope(Context* ctx, String* out_expected_type, Location loc = { -1, -1 })
{
	if (!ctx || !ctx.sf || ctx.offset == 0 || ctx.offset > ctx.sf.content.len) return EXECUTION;

	AttributeTargetKind attr_target = NONE;
	if (detect_attribute_context(ctx, loc, &attr_target))
	{
		ctx.attr_target = attr_target;
		return ATTRIBUTE;
	}

	String line_prefix = utils::extract_line_prefix(ctx.sf.content, ctx.offset);

	if (line_prefix == "import" || line_prefix.starts_with("import ") || line_prefix.starts_with("import\t") ||
	    line_prefix == "module" || line_prefix.starts_with("module ") || line_prefix.starts_with("module\t"))
	{
		return IMPORT;
	}

	String text_before = line_prefix[:line_prefix.len - ctx.prefix.len].trim();
	if (constants::is_type_decl_keyword(text_before))
	{
		return NONE;
	}

	if (text_before == "return" || text_before.starts_with("return "))
	{
		if (loc.line >= 0)
		{
			foreach (stmt : ctx.sf.ast.statements)
			{
				if (stmt && stmt.range.contains(loc) && stmt.kind == FN_DECL)
				{
					FnDecl* fd = stmt.as(FnDecl);
					if (fd.ret_type)
					{
						String rtype = cursor::raw_type_identifier(fd.ret_type) ?? cursor::spelling(fd.ret_type, tmem);
						rtype = rtype.trim_right("*&? \t");
						if (rtype.len > 0)
						{
							if (out_expected_type) *out_expected_type = rtype;
							return TYPE_ASSIGNMENT;
						}
					}
					break;
				}
			}
		}
	}

	String text_before_case = text_before;
	if (text_before_case.starts_with("case") || text_before_case.starts_with("$case"))
	{
		String rem = text_before_case.strip_prefix("$case").strip_prefix("case").trim();
		if (rem.len == 0 || rem == ":" || rem.starts_with(".."))
		{
			Node* switch_node = query::enclosing_switch(ctx.sf, loc);
			Node* cond = null;
			if (switch_node) cond = switch_node.kind == SWITCH_STMT ? switch_node.as(SwitchStmt).cond : switch_node.as(CtSwitchStmt).cond;
			// `switch (a, b)` switches on its last expression.
			if (cond && cond.kind == COND_EXPR) cond = cond.as(CondExpr).exprs.len ? cond.as(CondExpr).exprs[^1] : null;
			String switch_type = cond && ctx.ws && ctx.ws.ctx ? query::type_of(ctx.ws.ctx, ctx.sf, cond, loc) : "";
			if (switch_type.len > 0)
			{
				if (out_expected_type) *out_expected_type = switch_type;
				ctx.switch_node = switch_node;
				return TYPE_ASSIGNMENT;
			}
		}
		// Right after the label's `:`; a statement may follow on the same line.
		if (rem.ends_with(":") && !rem.ends_with("::") && !ctx.prefix.len) return NONE;
	}

	if ((text_before_case == "default:" || text_before_case == "$default:") && !ctx.prefix.len) return NONE;

	String text_before_cmp = line_prefix[:line_prefix.len - ctx.prefix.len].trim_right();
	if (text_before_cmp.ends_with("==") || text_before_cmp.ends_with("!="))
	{
		String lhs_part = text_before_cmp[:text_before_cmp.len - 2].trim_right();
		sz expr_start = utils::scan_base_expression_start(lhs_part, lhs_part.len);
		if (lhs_part.len > expr_start)
		{
			String lhs_expr = lhs_part[expr_start..].trim();
			if (lhs_expr.len > 0)
			{
				String resolved_type = type_of_text(ctx, ctx.sf, lhs_expr);
				if (resolved_type.len > 0)
				{
					if (out_expected_type) *out_expected_type = resolved_type;
					return TYPE_ASSIGNMENT;
				}
			}
		}
	}

	if (try eq_idx = line_prefix.rindex_of_char('='))
	{
		bool is_arrow = eq_idx + 1 < line_prefix.len && line_prefix[eq_idx + 1] == '>';
		if (!is_arrow && (eq_idx == 0 || (line_prefix[eq_idx - 1] != '=' && line_prefix[eq_idx - 1] != '!' && line_prefix[eq_idx - 1] != '<' && line_prefix[eq_idx - 1] != '>')))
		{
			String des_type = initializer_slot_type(ctx, ctx.sf);
			if (des_type.len > 0)
			{
				if (out_expected_type) *out_expected_type = des_type;
				return TYPE_ASSIGNMENT;
			}

			String lhs = line_prefix[:eq_idx].trim();
			sz clause_start = 0;
			int depth = 0;
			for (sz i = lhs.len; i > 0; i--)
			{
				char c = lhs[i - 1];
				if (c == ')' || c == ']' || c == '}')
				{
					depth++;
				}
				else if (c == '(' || c == '[' || c == '{')
				{
					if (depth > 0)
					{
						depth--;
					}
					else
					{
						clause_start = i;
						break;
					}
				}
				else if (depth == 0 && (c == ',' || c == ';'))
				{
					clause_start = i;
					break;
				}
			}
			String clause = lhs[clause_start..].trim();
			String[] words = clause.tsplit(" ");
			if (words.len >= 2)
			{
				String candidate_type = words[^2].trim().trim_right("*& \t");
				if (candidate_type.len > 0 && (candidate_type[0].is_upper() || candidate_type.contains("::") || candidate_type == "fault"))
				{
					if (out_expected_type) *out_expected_type = candidate_type;
					return TYPE_ASSIGNMENT;
				}
			}
			if (words.len >= 1)
			{
				String resolved_type = type_of_text(ctx, ctx.sf, words[^1].trim());
				if (resolved_type.len > 0)
				{
					if (out_expected_type) *out_expected_type = resolved_type;
					return TYPE_ASSIGNMENT;
				}
			}
		}
	}

	bool in_parens = false;
	if (ctx.sf && ctx.offset > 0)
	{
		CallTargetInfo target_info = utils::parse_call_context(ctx.sf.content, ctx.offset);
		in_parens = target_info.in_parens;
		if (target_info.is_valid && target_info.callee_name.len > 0)
		{
			String param_type = active_param_type(ctx, ctx.sf, target_info);
			if (param_type.len > 0 && out_expected_type) *out_expected_type = param_type;
		}
	}

	if (loc.line >= 0)
	{
		foreach (stmt : ctx.sf.ast.statements)
		{
			if (stmt && stmt.range.contains(loc))
			{
				switch (stmt.kind)
				{
					case FN_DECL:
						{
							FnDecl* fd = stmt.as(FnDecl);
							if (fd.body && fd.body.range.contains(loc)) return in_parens ? EXPRESSION : EXECUTION;
							return GLOBAL;
						}
					case MACRO_DECL:
						{
							MacroDecl* md = stmt.as(MacroDecl);
							if (md.body && md.body.range.contains(loc)) return in_parens ? EXPRESSION : EXECUTION;
							return GLOBAL;
						}
					case STRUCT_DECL:
						return CONTAINER;
					case ENUM_DECL:
						return ENUM;
					default:
						return GLOBAL;
				}
			}
		}
		return GLOBAL;
	}

	return EXECUTION;
}

fn void provide_expected_type_completions(Context* ctx, List{CompletionItem}* items, String type_name, HashSet{String}* excluded_names = null)
{
	if (!ctx.ws || type_name.len == 0) return;

	Node* node = query::find_type_node_in_context(ctx.ws.ctx, ctx.sf, type_name, ctx.loc);
	if (!node)
	{
		List{SymbolEntry} syms = ctx.ws.find_symbol_by_name(type_name, ctx.sf);
		if (syms.len() > 0 && syms.get(0).node)
		{
			node = syms.get(0).node;
		}
	}

	if (node && node.kind == ENUM_DECL)
	{
		EnumDecl* ed = node.as(EnumDecl);
		foreach (variant : ed.variants)
		{
			if (!variant || variant.kind != VAR_DECL) continue;
			VarDecl* vd = variant.as(VarDecl);
			String vname = vd.name ? vd.name.text : "";
			if (excluded_names && excluded_names.contains(vname)) continue;
			if (vname.len > 0 && fuzzy_match(vname, ctx.prefix))
			{
				items.push(
				{
					.label = vname,
					.kind = ENUMMEMBER,
					.detail = string::tformat("enum %s", type_name),
					.insertText = vname,
					.filterText = vname,
					.sortText = string::tformat("0000_%s", vname),
					.data = string::tformat("enum_variant:%s:%s", type_name, vname)
				}
				);
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Item Resolution
// ---------------------------------------------------------------------------

fn void resolve_item(LspProject* project, CompletionItem* item)
{
	if (!project || !item || item.label.len == 0) return;
	if (!item.detail.len) item.detail = item.labelDetails.description;

	if (item.documentation.kind.len == 0)
	{
		item.documentation.kind = MARKDOWN;
	}

	if (item.kind == KEYWORD) return;

	Node* target_node = null;

	if (item.data.len > 0)
	{

		//if (item.data == "property") return; /// why vscode, why you do this to me

		if (item.data.starts_with("local:"))
		{
			String vname = item.data.strip_prefix("local:");
			String vtype = item.detail.len > 0 ? item.detail : "var";
			DString md_buf;
			md_buf.tinit();
			md_buf.appendf("```c3\n%s %s\n```", vtype, vname);
			item.documentation = {
				.kind = MARKDOWN,
				.value = md_buf.str_view()
			};
			return;
		}

		if (item.data.starts_with("module:"))
		{
			String mod_name = item.data.strip_prefix("module:");
			String doc_comment = "";
			if (project.workspace.ctx)
			{
				Module* mod = analysis::find_module_by_identifier(&project.workspace, "", mod_name);
				if (mod && mod.module_decls.len() > 0)
				{
					doc_comment = declaration::docs((Node*)mod.module_decls.get(0));
				}
			}

			DString md_buf;
			md_buf.tinit();
			md_buf.appendf("```c3\nmodule %s\n```", mod_name);
			if (doc_comment.len > 0) md_buf.appendf("\n\n%s", doc_comment);

			item.documentation = {
				.kind = MARKDOWN,
				.value = md_buf.str_view()
			};
			return;
		}

		if (item.data.starts_with("enum_variant:"))
		{
			String payload = item.data.strip_prefix("enum_variant:");
			if (try colon_idx = payload.index_of_char(':'))
			{
				String enum_name = payload[:colon_idx];
				String variant_name = payload[colon_idx + 1..];

				List{SymbolEntry} syms = project.workspace.find_symbol_by_name(enum_name);
				if (syms.len() > 0 && syms.get(0).node && syms.get(0).node.kind == ENUM_DECL)
				{
					foreach (v : syms.get(0).node.as(EnumDecl).variants)
					{
						if (v && v.kind == VAR_DECL && v.as(VarDecl).name && v.as(VarDecl).name.text == variant_name)
						{
							target_node = v;
							break;
						}
					}
				}
			}
		}
		else if (item.data.starts_with("method:"))
		{
			String payload = item.data.strip_prefix("method:");
			if (try colon_idx = payload.index_of_char(':'))
			{
				String type_name = payload[:colon_idx];
				String method_name = payload[colon_idx + 1..];
				target_node = query::find_method_in_type(project.workspace.ctx, type_name, method_name);
			}
		}
		else if (item.data.starts_with("field:"))
		{
			String payload = item.data.strip_prefix("field:");
			if (try colon_idx = payload.index_of_char(':'))
			{
				String type_name = payload[:colon_idx];
				String field_name = payload[colon_idx + 1..];
				target_node = query::find_member_in_type(project.workspace.ctx, type_name, field_name);
			}
		}
		else if (item.data.starts_with("symbol:"))
		{
			String payload = item.data.strip_prefix("symbol:");
			String base = "";
			String sym = payload;
			if (try colon_idx = payload.index_of_char(':'))
			{
				base = payload[:colon_idx];
				sym = payload[colon_idx + 1..];
			}

			if (base.len > 0 && project.workspace.ctx)
			{
				AnalyzerContext* actx = project.workspace.ctx;
				Module* mod = analysis::find_module_by_identifier(&project.workspace, "", base);
				if (mod)
				{
					String qname = string::tformat("%s::%s", mod.name, sym);
					if (actx.registry)
					{
						if (try fn_info = actx.registry.functions.get(qname))
						{
							target_node = fn_info.node;
						}
						else if (try mac_info = actx.registry.macros.get(qname))
						{
							target_node = mac_info.node;
						}
						else if (try ty_info = actx.registry.types.get(qname))
						{
							target_node = ty_info.node;
						}
					}
					if (!target_node)
					{
						foreach (n : mod.nodes)
						{
							if (!n || n.kind == ERROR) continue;
							if (n.kind == FAULTDEF_DECL)
							{
								FaultdefDecl* fd = n.as(FaultdefDecl);
								foreach (fault_node : fd.faults)
								{
									if (!fault_node || fault_node.kind != FAULT_DECL) continue;
									FaultDecl* fdecl = fault_node.as(FaultDecl);
									if (fdecl.name && fdecl.name.text == sym)
									{
										target_node = fault_node;
										break;
									}
								}
								if (target_node) break;
							}
							String sname = cursor::spelling(n, tmem);
							if (sname == sym || sname.strip_prefix("@") == sym.strip_prefix("@"))
							{
								target_node = n;
								break;
							}
						}
					}
				}

				if (!target_node)
				{
					target_node = query::find_method_in_type(actx, base, sym);
				}
				if (!target_node)
				{
					target_node = query::find_member_in_type(actx, base, sym);
				}
			}
		}
	}

	if (item.kind == MODULE)
	{
		DString md_buf;
		md_buf.tinit();
		md_buf.appendf("```c3\nmodule %s\n```", item.label);
		item.documentation = {
			.kind = MARKDOWN,
			.value = md_buf.str_view()
		};
		return;
	}

	if (item.documentation.value.len > 0) return;

	String sym_name = item.label;

	if (!target_node)
	{
		List{SymbolEntry} syms = project.workspace.find_symbol_by_name(sym_name);
		if (syms.len() == 0 && sym_name.starts_with("@"))
		{
			syms = project.workspace.find_symbol_by_name(sym_name.strip_prefix("@"));
		}
		if (syms.len() > 0 && syms.get(0).node)
		{
			target_node = syms.get(0).node;
		}
	}

	if (!target_node) return;

	DString md_buf;
	md_buf.tinit();
	md_buf.append(declaration::header(project.workspace.ctx, target_node, sym_name));
	String doc_comment = declaration::docs(target_node);
	if (doc_comment.len > 0) md_buf.appendf("\n\n%s", doc_comment);

	item.documentation = {
		.kind = MARKDOWN,
		.value = md_buf.str_view()
	};
}

// ---------------------------------------------------------------------------
// Entry Point
// ---------------------------------------------------------------------------

<*
 Completion items at `pos`, each showing its `detail` on its row.
*>
fn CompletionItem[]? resolve(LspProject* project, Uri uri, LspPosition pos, CompletionContext context = {})
{
	CompletionItem[] items = collect(project, uri, pos, context)!;
	foreach (&item : items) item.labelDetails.description = item.detail;
	return items;
}

fn CompletionItem[]? collect(LspProject* project, Uri uri, LspPosition pos, CompletionContext context) @local
{
	List{CompletionItem} items;
	items.init(tmem);

	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf) return items.array_view();

	sz offset = utils::compute_byte_offset(sf.content, pos.line, pos.character);

	Location loc = {
		.line = (int)pos.line,
		.column = (int)pos.character
	};
	if (sf.lexer && sf.lexer.in_comment(loc)) return items.array_view();

	String caller_mod = query::get_module_name_at_location(sf, loc);

	bool is_stmt = false;
	if (offset <= sf.content.len)
	{
		sz p = offset;
		is_stmt = true;
		while (p < sf.content.len && sf.content[p] != '\n')
		{
			if (sf.content[p] == ';') { is_stmt = false; break; }
			p++;
		}
	}

	Context ctx = {
		.uri = uri,
		.position = pos,
		.loc = loc,
		.offset = offset,
		.ws = &project.workspace,
		.sf = sf,
		.allocator = tmem,
		.scope = EXECUTION,
		.attr_target = NONE,
		.access = NONE,
		.base_identifier = "",
		.expected_type = "",
		.caller_mod = caller_mod,
		.missing_second_colon = false,
		.is_designated_initializer = false,
		.designated_has_dot = false,
		.is_stmt = is_stmt
	};

	ctx.prefix = utils::extract_prefix(sf.content, ctx.offset);

	// After `$$` only the compiler's builtins fit.
	if (ctx.prefix.starts_with("$$"))
	{
		foreach (b : constants::Builtin::values)
		{
			String label = string::tformat("$$%s", b.name);
			if (!fuzzy_match(label, ctx.prefix)) continue;
			InsertTextFormat format = PLAIN_TEXT;
			String insert_text = label;
			if (!has_lparen_ahead(&ctx))
			{
				DString out;
				out.tinit();
				append_snippet_text(&out, label);
				out.append_char('(');
				int tabstop = 1;
				foreach (param : b.params.tsplit(", "))
				{
					if (!param.len || param.contains("...") || param.contains("=")) continue;
					if (tabstop > 1) out.append(", ");
					out.appendf("${%d:", tabstop++);
					append_snippet_text(&out, param);
					out.append_char('}');
				}
				out.append_char(')');
				if (tabstop > 1)
				{
					format = SNIPPET;
					insert_text = out.str_view();
				}
				else
				{
					insert_text = string::tformat("%s()", label);
				}
			}
			items.push({ .label = label, .kind = FUNCTION, .detail = b.signature(), .documentation = { .kind = MARKDOWN, .value = b.doc },
				.insertText = insert_text, .insertTextFormat = format, .filterText = label, .sortText = string::tformat("0001_%s", b.name),
				.textEdit = replace_typed(&ctx, insert_text) });
		}
		foreach (c : constants::BuiltinConstant::values)
		{
			String label = string::tformat("$$%s", c.name);
			if (!fuzzy_match(label, ctx.prefix)) continue;
			items.push({ .label = label, .kind = CONSTANT, .detail = "compiler builtin constant", .documentation = { .kind = MARKDOWN, .value = c.doc },
				.insertText = label, .filterText = label, .sortText = string::tformat("0001_%s", c.name), .textEdit = replace_typed(&ctx, label) });
		}
		return items.array_view();
	}

	String expected_type = "";
	ScopeKind scope = detect_completion_scope(&ctx, &expected_type, loc);
	ctx.scope = scope;
	ctx.expected_type = expected_type;

	detect_access_context(&ctx, sf);

	sz word_start = sf.lexer ? sf.lexer.first_token_at({ loc.line, loc.column - (int)ctx.prefix.len }) : 0;
	TokenKind jump = word_start ? sf.lexer.tokens[word_start - 1].kind : EOF;
	bool space_triggered = context.triggerKind == TRIGGER_CHARACTER && context.triggerCharacter == " ";
	if (space_triggered && ctx.scope != IMPORT && !expected_type.len && jump != BREAK && jump != CONTINUE && jump != NEXTCASE)
	{
		return items.array_view();
	}

	if (jump == NEXTCASE) provide_labels(&ctx, &items, loc, jump);

	if (ctx.scope == NONE)
	{
		return items.array_view();
	}
	else if (jump == BREAK || jump == CONTINUE)
	{
		provide_labels(&ctx, &items, loc, jump);
	}
	else if (ctx.scope == ATTRIBUTE)
	{
		provide_builtin_attributes_for_target(&ctx, &items, ctx.attr_target);
		if (ctx.attr_target != IMPORT && ctx.attr_target != MODULE && ctx.attr_target != CALL && ctx.attr_target != SWITCH && ctx.attr_target != ATTRDEF)
		{
			provide_attrmacros(&ctx, &items);
		}
	}
	else if (ctx.scope == IMPORT)
	{
		provide_module_paths(&ctx, &items, sf, offset);
	}
	else if ((jump == IDENT || jump == CONST_IDENT || jump == CT_IDENT) && sf.lexer.tokens[word_start - 1].range.end.line == loc.line)
	{
		// No identifier follows an identifier on its line; a declared name takes only attributes.
		return items.array_view();
	}
	else if (ctx.access != NONE)
	{
		provide_member_access(&ctx, &items);
	}
	else
	{
		bool is_enum_expected = false;
		if (expected_type.len > 0 && project.workspace.ctx)
		{
			Node* node = query::find_type_node_in_context(project.workspace.ctx, sf, expected_type, loc);
			if (!node)
			{
				List{SymbolEntry} syms = project.workspace.find_symbol_by_name(expected_type, sf);
				if (syms.len() > 0 && syms.get(0).node) node = syms.get(0).node;
			}
			if (node && node.kind == ENUM_DECL)
			{
				is_enum_expected = true;
			}
		}

		if (is_enum_expected)
		{
			bool in_switch = ctx.switch_node != null;
			HashSet{String} seen_cases;
			seen_cases.tinit();
			if (in_switch && ctx.sf)
			{
				collect_already_handled_cases(ctx.switch_node, { (int)ctx.position.line, (int)ctx.position.character }, &seen_cases);
			}
			provide_named_args(&ctx, &items);
			provide_expected_type_completions(&ctx, &items, expected_type, in_switch ? &seen_cases : null);
			provide_locals(&ctx, &items);
			provide_global(&ctx, &items);
			provide_modules(&ctx, &items);
		}
		else
		{
			bool in_type_pos = is_type_position(&ctx);
			if (in_type_pos)
			{
				provide_builtin_types(&ctx, &items);
				provide_global_types_only(&ctx, &items);
				provide_modules(&ctx, &items);
				provide_generic_params(&ctx, &items);

				sz p = ctx.offset - ctx.prefix.len;
				while (p > 0 && (ctx.sf.content[p - 1] == ' ' || ctx.sf.content[p - 1] == '\t')) p--;
				if (p > 0 && ctx.sf.content[p - 1] == ':')
				{
					if (fuzzy_match("inline", ctx.prefix))
					{
						items.push(
						{
							.label = "inline",
							.kind = KEYWORD,
							.detail = "Keyword",
							.insertText = "inline",
							.filterText = "inline",
							.sortText = "0000_inline"
						}
						);
					}
				}
			}
			else
			{
				provide_named_args(&ctx, &items);
				if (expected_type.len > 0)
				{
					provide_expected_type_completions(&ctx, &items, expected_type);
				}
				provide_locals(&ctx, &items);
				provide_generic_params(&ctx, &items);
				provide_global(&ctx, &items);
				provide_modules(&ctx, &items);
				provide_builtin_types(&ctx, &items);
				provide_keywords(&ctx, &items);
			}
		}
	}

	// Clients do not count `$` or `#` as part of the word, so they would keep the typed sigil.
	bool sigil_typed = ctx.prefix.starts_with("$") || ctx.prefix.starts_with("#");
	foreach (&item : items)
	{
		if (item.documentation.value.len && !item.documentation.kind.len)
		{
			item.documentation.kind = MARKDOWN;
		}
		if (sigil_typed && !item.textEdit) item.textEdit = replace_typed(&ctx, item.insertText ?: item.label);
	}

	return items.array_view();
}