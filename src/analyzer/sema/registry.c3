module analyzer::sema::registry;
import analyzer, std::collections, std::io;

fn Registry* create(Allocator alloc)
{
	Registry* registry = alloc::new(alloc, Registry);

	registry.arena.init(alloc, 4096);

	registry.functions.init(&registry.arena);
	registry.types.init(&registry.arena);
	registry.macros.init(&registry.arena);
	registry.attrmacros.init(&registry.arena);
	registry.methods_by_type.init(&registry.arena);

	return registry;
}

fn void free(AnalyzerContext* context, Registry* reg)
{
	if (!reg) return;
	reg.arena.free();

	alloc::free(context.allocator, reg);
}

fn void register(AnalyzerContext* context, SourceFile* sf) => @pool()
{
	Module* current_mod;

	foreach (Node* statement : sf.ast.statements)
	{
		if (!statement || statement.kind == CONTRACT_DECL) continue;

		switch (statement.kind)
		{
			case MODULE_DECL:
				ModuleDecl* mod_decl = statement.as(ModuleDecl);
				if (try path_node = mod_decl.path.get())
				{
					PathExpr* path = path_node.as(PathExpr);
					if (path.path.text.len > 0)
					{
						current_mod = mod::create(context, path.path.text);
					}
				}
			default:
				break;
		}

		if (current_mod == null)
		{
			String mod_name = query::file_stem_from_path(sf.path);
			if (mod_name.len == 0) mod_name = "default";
			current_mod = mod::create(context, mod_name);
		}

		register_and_dispatch(context, current_mod, statement);
	}
}

fn void register_and_dispatch(AnalyzerContext* context, Module* mod, Node* node)
{
	mod::add_node(mod, node);

	switch (node.kind)
	{
		case STRUCT_DECL:
		case ENUM_DECL:
		case TYPEDEF_DECL:
		case ALIAS_DECL:
		case INTERFACE_DECL:
			register_type(context, mod, node);
		case FN_DECL:
			register_function(context, mod, node);
		case MACRO_DECL:
			register_macro(context, mod, node);
		case ATTRDEF_DECL:
			register_attrdef(context, mod, node);
		default:
			break;
	}
}

<*
 Adds `node` of `mod` to the front of its `mod::name` list in `#map`.
 @return "The qualified name, or \"\" when the declaration has no name"
*>
macro String @register(#map, $Info, AnalyzerContext* context, Module* mod, Node* node) @local
{
	Ident*? name = cursor::decl_name(node);
	if (catch name) return "";
	String qname = string::format(&context.registry.arena, "%s::%s", mod.name, name.text);
	$Info* info = alloc::new(&context.registry.arena, $Info);
	*info = { .next = #map.get(qname) ?? null, .mod = mod.name, .node = node };
	#map.set(qname, info);
	return qname;
}

fn void register_type(AnalyzerContext* context, Module* mod, Node* node)
{
	switch (node.kind)
	{
		case STRUCT_DECL:
		case ENUM_DECL:
		case TYPEDEF_DECL:
		case ALIAS_DECL:
		case INTERFACE_DECL:
			break;
		default:
			return;
	}

	String qname = @register(context.registry.types, TypeInfo, context, mod, node);
	if (qname.len) lookup::register_type(context.lookup, context.allocator, qname);
}

fn void register_function(AnalyzerContext* context, Module* mod, Node* node)
{
	@register(context.registry.functions, FunctionInfo, context, mod, node);
	if (try receiver = node.as(FnDecl).associated_type.get()) register_method(context, mod, node, receiver);
}

fn void register_macro(AnalyzerContext* context, Module* mod, Node* node)
{
	@register(context.registry.macros, MacroInfo, context, mod, node);
	if (try receiver = node.as(MacroDecl).associated_type.get()) register_method(context, mod, node, receiver);
}

<*
 Indexes the method `node` under the name of its receiver type, and a
 method of vectors also under ANY_VECTOR.
*>
fn void register_method(AnalyzerContext* context, Module* mod, Node* node, Node* receiver) @local
{
	String type_name = cursor::raw_type_identifier(receiver) ?? "";
	if (!type_name.len) return;
	index_method(context, mod, node, type_name);
	if (receiver.kind == TYPE_EXPR && receiver.as(TypeExpr).type_kind == TYPE_VECTOR) index_method(context, mod, node, query::ANY_VECTOR);
}

fn void index_method(AnalyzerContext* context, Module* mod, Node* node, String key) @local
{
	MethodInfo* info = alloc::new(&context.registry.arena, MethodInfo);
	*info = { .next = context.registry.methods_by_type.get(key) ?? null, .mod = mod.name, .node = node };
	context.registry.methods_by_type.set(key.copy(&context.registry.arena), info);
}

fn void register_attrdef(AnalyzerContext* context, Module* mod, Node* node)
{
	@register(context.registry.attrmacros, AttrdefInfo, context, mod, node);
}
