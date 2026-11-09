module lsp::bindgen;

import std;

const String LAYOUT_PROBE_PREFIX = "__c3_align_";

<*
 Whether `st` has layout attributes that need clang's field alignments: `#pragma pack`, `packed`
 or aligned fields.
*>
fn bool needs_layout_probe(CStruct* st) @local
{
	return (st.is_packed || st.has_aligned_field) && !st.is_opaque && !st.is_bitfield && st.c_object.len > 0;
}

fn String layout_probe_name(sz struct_index, sz field_index, bool natural) @local
{
	return string::tformat("%s%d_%d_%s", LAYOUT_PROBE_PREFIX, struct_index, field_index, natural ? "natural" : "effective");
}

<*
 Probe declarations whose array lengths are the effective and the natural alignment of each named
 field of the records that need them.
*>
fn String build_layout_probe(CTranslationUnit* tu)
{
	DString out;
	out.tinit();
	foreach (i, &st : tu.structs)
	{
		if (!needs_layout_probe(st)) continue;
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
 Applies the probed field alignments. A packed record keeps @packed and gives its fields their
 effective alignment, unless every field is probed and already at its natural alignment, as under a
 `#pragma pack` wider than its fields. Other records align only the fields C over-aligns.
*>
fn void parse_layout_probe(CTranslationUnit* tu, Object* probe_root)
{
	HashMap{String, uint} alignments;
	alignments.tinit();
	foreach (node : inner_nodes(probe_root))
	{
		String name = node.get_string("name") ?? "";
		if (!name.starts_with(LAYOUT_PROBE_PREFIX) || (node.get_bool("isInvalid") ?? false)) continue;
		String array_type = node.get("type").get_string("qualType") ?? "";
		sz? open = array_type.index_of_char('[');
		if (catch open) continue;
		uint? alignment = array_type[open + 1..].trim_right("]").to_uint();
		if (try alignment) alignments.set(name, alignment);
	}

	foreach (i, &st : tu.structs)
	{
		if (!needs_layout_probe(st)) continue;
		uint[] effective = mem::temp_array(uint, st.fields.len());
		uint[] natural = mem::temp_array(uint, st.fields.len());
		bool is_natural_layout = true;
		foreach (j, f : st.fields)
		{
			uint? field_effective = alignments.get(layout_probe_name(i, j, false));
			uint? field_natural = alignments.get(layout_probe_name(i, j, true));
			if (catch field_effective, field_natural)
			{
				is_natural_layout = false;
				continue;
			}
			effective[j] = field_effective;
			natural[j] = field_natural;
			if (field_effective != field_natural) is_natural_layout = false;
		}
		if (is_natural_layout) st.is_packed = false;

		foreach (j, &f : st.fields)
		{
			if (st.is_packed ? effective[j] > 1 : effective[j] > natural[j]) f.alignment = effective[j];
		}
	}
}
