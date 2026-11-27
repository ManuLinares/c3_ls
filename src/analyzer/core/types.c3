module analyzer::core;

import std::collections;
import std::core::mem::allocators;

import analyzer::sema;
import analyzer::lexer;

struct SourceFile
{
	DynamicArenaAllocator arena;
	Lexer* lexer;
	String path;
	String content;
	Ast ast;
	NodeID min_node_id;
	NodeID max_node_id;
	HashSet{String} identifiers; // Every identifier spelled in `content`.
	<* Features enabled for this file in addition to the context's, such as TESTING in a test file. *>
	String[] features;
}

<*
 False when `name` is never spelled as an identifier in this file.
*>
fn bool SourceFile.mentions(&self, String name) @inline => self.identifiers.contains(name);

fn bool SourceFile.contains_node(&self, Node* node) @inline
{
	if (!node) return false;
	return node.id >= self.min_node_id && node.id < self.max_node_id;
}

<*
 -`nodes`: all nodes in this module with order preserved
 -`module_decls`: a index table for fast lookup of all modules/sections in this module
*>
struct Module
{
	String name;
	List{Node*} nodes;
	List{ModuleDecl*} module_decls;
}

struct Lookup
{
	DynamicArenaAllocator arena;
	HashMap{String, Type*} types;
	Allocator alloc;
	Target target;
}

struct AnalyzerContext
{
	HashMap{String, SourceFile*} files;
	List{SourceFile*} files_by_node_id;
	HashMap{String, Module*} modules;
	Lookup* lookup;
	Registry* registry;
	Allocator allocator;
	SourceFile* current_source_file;
	Target target;
	<* Features enabled for `target`, which `@feat` conditions are evaluated against. *>
	String[] features;
}

struct ParseContext
{
	AnalyzerContext* context;
	SourceFile* sf;
	Ast* ast;
	Lexer* lexer;
	Allocator allocator;
	Node* contract;
	Token current;
	int pos;
	int error_count;
	Visibility current_section_visibility;
}

struct FunctionInfo
{
	FunctionInfo* next;
	String mod;
	Node* node;
}

struct MacroInfo
{
	MacroInfo* next;
	String mod;
	Node* node;
}

enum TypeModifierKind : char
{
	NONE,
	POINTER,
	SLICE,
	ARRAY,
	CONST,
}

struct ImportInfo
{
	String path;
	Node* node;
}

fn bool ImportInfo.eq(self, ImportInfo other) @operator(==)
{
	return self.path == other.path && self.node == other.node;
}

struct TypeInfo
{
	TypeInfo* next;
	String mod;
	Node* node;
}

struct VariableInfo
{
	String name;
	Node* node;
}

struct MethodInfo
{
	MethodInfo* next;
	String mod;
	Node* node;
}

struct AttrdefInfo
{
	AttrdefInfo* next;
	String mod;
	Node* node;
}

struct Registry
{
	DynamicArenaAllocator arena;
	HashMap{String, TypeInfo*} types;
	HashMap{String, FunctionInfo*} functions;
	HashMap{String, MacroInfo*} macros;
	HashMap{String, AttrdefInfo*} attrmacros;
	HashMap{String, MethodInfo*} methods_by_type;
}

struct Scope
{
	Scope* parent;
	Range range;
	List{Scope*} children;
	HashMap{String, VariableInfo*} variables;
}

enum ResolveStatus : char
{
	UNRESOLVED,
	RESOLVED
}

struct Type
{
	TypeKind kind;
	ResolveStatus status;
	uint size;
	String name;

	union data
	{
		bitstruct builtin : uint
		{
			char bitsize: 0..7;
			char bytesize: 8..15;
			char abi_alignment: 16..23;
			char pref_alignment: 24..31;
		}
	}
}

fn bool Type.is_struct(&self) @inline => self.kind == TYPE_STRUCT || self.kind == TYPE_UNION || self.kind == TYPE_BITSTRUCT;
fn bool Type.is_enum(&self) @inline => self.kind == TYPE_ENUM;
fn bool Type.is_float(&self) @inline => self.kind >= TYPE_F16 && self.kind <= TYPE_F128;

struct Target
{
	OsType os;
	ArchType arch;
	TargetLayout layout;
}

struct AlignData
{
	uint align;
	uint pref_align;
}

struct TargetLayout
{
	AlignData[BitSizes::len] integers;
	AlignData[BitSizes::len] floats;
}
