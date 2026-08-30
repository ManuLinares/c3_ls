module analyzer::sema::lookup;

import analyzer::core;
import analyzer::core::arch;
import analyzer::cursor;

fn Lookup* create(AnalyzerContext* context, Allocator alloc)
{
	Lookup* lookup = alloc::new(alloc, Lookup);

	lookup.arena.init(alloc, 4096);
	lookup.types.init(&lookup.arena);
	lookup.alloc = alloc;
	lookup.target = context.target;

	init_builtin_types(lookup);

	return lookup;
}

fn void free(AnalyzerContext* context, Lookup* lookup)
{
	if (!lookup) return;

	lookup.types.free();
	lookup.arena.free();
	alloc::free(context.allocator, lookup);
}

fn void register_type(Lookup* lookup, Allocator alloc, String name, Node* node)
{
	if (try old_type = lookup.types.get(name))
	{
		old_type.data.node = node;
		old_type.status = UNRESOLVED;
		return;
	}

	Type* type = alloc::new(&lookup.arena, Type);

	type.name = name.copy(&lookup.arena);
	type.data.node = node;
	type.status = UNRESOLVED;

	lookup.types.set(type.name, type);
}

fn void create_builtin(Lookup* lookup, String name,
TypeKind kind, BitSizes bits, char bytes)
{
	Type* type = alloc::new(&lookup.arena, Type);
	type.name = name.copy(&lookup.arena);
	type.kind = kind;
	type.status = RESOLVED;

	type.data.builtin.bitsize = bits.ordinal;
	type.data.builtin.bytesize = bytes;

	AlignData align;
	switch (kind)
	{
		case TYPE_F16:
		case TYPE_F32:
		case TYPE_F64:
		case TYPE_F128:
			align = lookup.target.layout.floats[bits.ordinal];
		default:
			align = lookup.target.layout.integers[bits.ordinal];
	}

	type.data.builtin.abi_alignment = align.align > 0 ? (char)align.align : bytes;
	type.data.builtin.pref_alignment = align.pref_align > 0 ? (char)align.pref_align : bytes;

	lookup.types.set(type.name, type);
}

fn void init_builtin_types(Lookup* lookup)
{
	char psize = arch::ptr_size(lookup.target.arch);
	BitSizes pbits = arch::is_64bit(lookup.target.arch) ? BITS64 : BITS32;

	create_builtin(lookup, "void", TYPE_VOID, BIT1, 1);
	create_builtin(lookup, "bool", TYPE_BOOL, BITS8, 1);

	create_builtin(lookup, "ichar", TYPE_I8, BITS8, 1);
	create_builtin(lookup, "char", TYPE_U8, BITS8, 1);

	create_builtin(lookup, "short", TYPE_I16, BITS16, 2);
	create_builtin(lookup, "ushort", TYPE_U16, BITS16, 2);

	create_builtin(lookup, "int", TYPE_I32, BITS32, 4);
	create_builtin(lookup, "uint", TYPE_U32, BITS32, 4);

	create_builtin(lookup, "long", TYPE_I64, BITS64, 8);
	create_builtin(lookup, "ulong", TYPE_U64, BITS64, 8);

	create_builtin(lookup, "int128", TYPE_I128, BITS128, 16);
	create_builtin(lookup, "uint128", TYPE_U128, BITS128, 16);

	create_builtin(lookup, "float", TYPE_F32, BITS32, 4);
	create_builtin(lookup, "double", TYPE_F64, BITS64, 8);

	create_builtin(lookup, "sz", TYPE_SZ, pbits, psize);
	create_builtin(lookup, "usz", TYPE_USZ, pbits, psize);

	create_builtin(lookup, "iptr", TYPE_IPTR, pbits, psize);
	create_builtin(lookup, "uptr", TYPE_UPTR, pbits, psize);

	create_builtin(lookup, "String", TYPE_STRUCT, BITS128, 16);
	create_builtin(lookup, "any", TYPE_STRUCT, BITS128, 16);
	create_builtin(lookup, "typeid", TYPE_IPTR, pbits, psize);
	create_builtin(lookup, "fault", TYPE_IPTR, pbits, psize);
}

fn Type* get_type_by_name(Lookup* lookup, String name)
{
	if (!lookup || name.len == 0) return null;
	return lookup.types.get(name) ?? null;
}
