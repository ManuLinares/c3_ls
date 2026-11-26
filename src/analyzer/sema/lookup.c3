module analyzer::sema::lookup;

import analyzer::core;
import analyzer::core::arch;
import analyzer::core::constants;
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
	lookup.arena.free();
	alloc::free(context.allocator, lookup);
}

fn void register_type(Lookup* lookup, Allocator alloc, String name)
{
	if (try old_type = lookup.types.get(name))
	{
		old_type.status = UNRESOLVED;
		return;
	}

	Type* type = alloc::new(&lookup.arena, Type);

	type.name = name.copy(&lookup.arena);
	type.status = UNRESOLVED;

	lookup.types.set(type.name, type);
}

fn void init_builtin_types(Lookup* lookup)
{
	foreach (pt : PrimitiveType::values)
	{
		if (pt.kind == COMPILE_TIME) continue;
		char bytes = pt.size ? (char)pt.size : arch::ptr_size(lookup.target.arch);
		BitSizes bits = core::int_to_bit_size((sz)bytes * 8);

		Type* type = alloc::new(&lookup.arena, Type);
		type.name = pt.name.copy(&lookup.arena);
		type.kind = pt.type_kind;
		type.status = RESOLVED;
		type.data.builtin.bitsize = bits.ordinal;
		type.data.builtin.bytesize = bytes;

		AlignData align = pt.kind == FLOAT ? lookup.target.layout.floats[bits.ordinal] : lookup.target.layout.integers[bits.ordinal];
		type.data.builtin.abi_alignment = align.align > 0 ? (char)align.align : bytes;
		type.data.builtin.pref_alignment = align.pref_align > 0 ? (char)align.pref_align : bytes;

		lookup.types.set(type.name, type);
	}
}

fn Type*? get_type_by_name(Lookup* lookup, String name)
{
	if (!lookup || name.len == 0) return NOT_FOUND~;
	return lookup.types.get(name);
}
