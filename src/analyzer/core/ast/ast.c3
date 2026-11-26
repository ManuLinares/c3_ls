module analyzer::core::ast;
import analyzer::core, std::collections::list, std::collections::ref;

alias NodeArray = Node*[];
alias NullableNode = Nullable{Node};
alias NullableIdent = Nullable{Ident};
alias NullableGenerics = Nullable{GenericDecl};
alias NullableType = Nullable{Type};

<*
 Text of the name, or "" when there is none.
*>
fn String NullableIdent.text(self) => self.get().text ?? "";
fn bool NullableIdent.is(self, String text) => self.text() == text;

<*
 Whether the field holds `node`.
*>
fn bool NullableNode.is(self, Node* node) => (self.get() == node) ?? false;

<*
 Whether the field holds a node whose range contains `loc`.
*>
fn bool NullableNode.contains(self, Location loc) => self.get().range.contains(loc) ?? false;

<*
 The result of a pointer lookup as a Nullable reference, for storing it: null when the lookup found nothing.
 `$Typeof(#lookup!!)` only names the pointer type; it is never evaluated, so it cannot panic.
*>
macro @nullable(#lookup) => ref::nullable(#lookup ?? ($Typeof(#lookup!!))null);

typedef NodeID = inline ulong;

NodeID next_node_id = (NodeID)1;

bitstruct NodeFlags : ushort
{
	bool is_inline;
	bool is_static;
	bool is_extern;
	bool has_attributes;
	bool has_error;
	<* Made by the parser, with no source text of its own. *>
	bool is_synthetic;
}

struct Node
{
	NodeKind kind;
	Visibility visibility;
	NodeFlags flags;
	Range range;
	NodeID id;
	NullableType resolved_type;
}

<*
 @require self.kind == NodeKind.$eval(@typename_to_constname($Type::name)) : "Invalid kind to cast"
*>
macro Node.as(&self, $Type) => ($Type*)self;

struct Ast
{
	Allocator allocator;
	List{Node*} nodes;
	List{Node*} statements;
	List{sz} module_decls;
	List{sz} import_decls;
}

macro Node* Ast.error(&self, Range range)
{
	Node* node = (Node*)self.alloc_node(Error, range);
	node.flags.has_error = true;
	return node;
}

<*
 Allocates and initializes a strongly typed AST node inside the AST arena.
 Returns a typed pointer to the node.
*>
macro Ast.alloc_node(&self, $Type, Range range)
{
	$Type* node;
	$if $Type::alignment > mem::DEFAULT_MEM_ALIGNMENT:
		node = alloc::new_aligned(self.allocator, $Type)!!;
	$else
		node = alloc::new(self.allocator, $Type);
	$endif

	node.kind = NodeKind.$eval(@typename_to_constname($Type::name));
	node.range = range;
	node.id = next_node_id++;
	self.nodes.push(node);

	return node;
}

macro String @typename_to_constname(String $typename) @const
{
	var $name = "";
	$foreach $i, $c : $typename:
		$if $i != 0 &&& $c >= 'A' &&& $c <= 'Z':
			$name +++= "_";
		$endif
		$name +++= @str_upper("" +++ $c);
	$endforeach

	return $name;
}
