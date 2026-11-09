module lsp::bindgen;

import std;

const String LAYOUT_PROBE_PREFIX = "__c3_align_";

<*
 Whether `st` has layout attributes that need clang's field alignments: `#pragma pack`, `packed`
 or aligned fields.
*>
fn bool needs_layout_probe(CStruct* st) @local
{
	return (st.is_packed || st.has_aligned_field) && !st.is_opaque && st.c_object.len > 0;
}

fn String layout_probe_name(sz struct_index, sz field_index, bool natural) @local
{
	return string::tformat("%s%d_%d_%s", LAYOUT_PROBE_PREFIX, struct_index, field_index, natural ? "natural" : "effective");
}

fn String record_probe_name(sz struct_index) @local
{
	return string::tformat("%s%d_record", LAYOUT_PROBE_PREFIX, struct_index);
}

<*
 Probe declarations whose array lengths are the alignment of each record that needs them, and the
 effective and natural alignment of its named fields. Bitfields cannot be named in __alignof__, so
 their storage units are aligned from the record's alignment instead.
*>
fn String build_layout_probe(CTranslationUnit* tu)
{
	DString out;
	out.tinit();
	foreach (i, &st : tu.structs)
	{
		if (!needs_layout_probe(st)) continue;
		out.appendf("static char %s[__alignof__(%s)];\n", record_probe_name(i), st.c_object);
		foreach (j, f : st.fields)
		{
			if (f.bit_width >= 0 || f.c_name.len == 0) continue;
			out.appendf("static char %s[__alignof__(%s.%s)];\n", layout_probe_name(i, j, false), st.c_object, f.c_name);
			out.appendf("static char %s[__alignof__(__typeof__(%s.%s))];\n", layout_probe_name(i, j, true), st.c_object, f.c_name);
		}
	}
	return out.str_view();
}

<*
 Effective and natural alignment of each field of a record that needs the layout probe.
*>
struct RecordLayout @local
{
	uint[] effective;
	uint[] natural;
	uint record_alignment;
	bool is_resolved; // Every field's alignments are known.
	bool is_natural; // Every field sits at its natural alignment, so packing changes nothing.
}

enum ResolveState : char @local
{
	UNVISITED,
	VISITING,
	DONE,
}

struct LayoutResolver @local
{
	CTranslationUnit* tu;
	HashMap{String, uint} probed;
	HashMap{String, sz} index_by_name;
	RecordLayout[] layouts;
	ResolveState[] states;
}

<*
 Resolves record `index`, first resolving the anonymous records it holds by value, which may be
 declared after it when the record was forward-declared.
*>
fn RecordLayout* LayoutResolver.resolve(&self, sz index)
{
	RecordLayout* layout = &self.layouts[index];
	if (self.states[index] != UNVISITED) return layout;
	self.states[index] = VISITING;
	CStruct* st = &self.tu.structs[index];
	*layout = {
		.effective = mem::temp_array(uint, st.fields.len()),
		.natural = mem::temp_array(uint, st.fields.len()),
		.record_alignment = self.probed.get(record_probe_name(index)) ?? 0,
		.is_resolved = true,
		.is_natural = true,
	};
	foreach (j, f : st.fields)
	{
		uint[2]? field = self.field_alignments(index, j, f, layout.record_alignment);
		if (catch field)
		{
			layout.is_resolved = false;
			layout.is_natural = false;
			continue;
		}
		layout.effective[j] = field[0];
		layout.natural[j] = field[1];
		if (field[0] != field[1]) layout.is_natural = false;
	}
	self.states[index] = DONE;
	return layout;
}

<*
 Effective and natural alignment of field `field_index` of record `struct_index`. Named fields come
 from the probe. Bitfield storage units and anonymous members cannot be named in __alignof__, so
 they are capped by the record's alignment, which a pack bounds them by, from the unit's size or
 the anonymous record's resolved alignments.
*>
fn uint[2]? LayoutResolver.field_alignments(&self, sz struct_index, sz field_index, CField f, uint record_alignment)
{
	if (f.bit_width >= 0 || f.c_name.len == 0)
	{
		if (record_alignment == 0) return NOT_FOUND~;
		uint[2] member = f.bit_width >= 0 ? { (uint)f.storage_bits / 8, (uint)f.storage_bits / 8 } : self.anonymous_record_alignments(f.c3_type)!;
		if (member[1] == 0) return NOT_FOUND~;
		return { min(member[0], record_alignment), member[1] };
	}
	return { self.probed.get(layout_probe_name(struct_index, field_index, false))!, self.probed.get(layout_probe_name(struct_index, field_index, true))! };
}

fn uint[2]? LayoutResolver.anonymous_record_alignments(&self, String c3_name)
{
	sz index = self.index_by_name.get(c3_name)!;
	if (self.states[index] == VISITING) return NOT_FOUND~;
	RecordLayout* layout = self.resolve(index);
	if (!layout.is_resolved) return NOT_FOUND~;
	uint effective = array::@reduce(layout.effective, 0u, fn uint(uint acc, uint value, sz i) => max(acc, value));
	uint natural = array::@reduce(layout.natural, 0u, fn uint(uint acc, uint value, sz i) => max(acc, value));
	return { effective, natural };
}

<*
 Applies the probed field alignments. A packed record keeps @packed and gives its fields their
 effective alignment, unless every field is resolved and already at its natural alignment, as under
 a `#pragma pack` wider than its fields. Other records align only the fields C over-aligns.
*>
fn void parse_layout_probe(CTranslationUnit* tu, Object* probe_root)
{
	LayoutResolver resolver = {
		.tu = tu,
		.layouts = mem::temp_array(RecordLayout, tu.structs.len()),
		.states = mem::temp_array(ResolveState, tu.structs.len()),
	};
	resolver.probed.tinit();
	resolver.index_by_name.tinit();
	foreach (node : inner_nodes(probe_root))
	{
		String name = node.get_string("name") ?? "";
		if (!name.starts_with(LAYOUT_PROBE_PREFIX) || (node.get_bool("isInvalid") ?? false)) continue;
		String array_type = node.get("type").get_string("qualType") ?? "";
		sz? open = array_type.index_of_char('[');
		if (catch open) continue;
		uint? alignment = array_type[open + 1..].trim_right("]").to_uint();
		if (try alignment) resolver.probed.set(name, alignment);
	}
	foreach (i, &st : tu.structs)
	{
		if (needs_layout_probe(st)) resolver.index_by_name.set(st.c3_name, i);
	}

	foreach (i, &st : tu.structs)
	{
		if (!needs_layout_probe(st)) continue;
		RecordLayout* layout = resolver.resolve(i);
		if (layout.is_natural) st.is_packed = false;
		foreach (j, &f : st.fields)
		{
			if (st.is_packed ? layout.effective[j] > 1 : layout.effective[j] > layout.natural[j]) f.alignment = layout.effective[j];
		}
		if (st.is_bitfield && st.is_packed) st.alignment = layout.record_alignment;
	}
}
