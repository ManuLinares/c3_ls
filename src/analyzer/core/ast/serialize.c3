module analyzer::core::ast::serialize @feat(ANALYZER_CLI | EMSCRIPTEN);
import analyzer, std::collections::ref, std::collections::maybe, std::io;

alias JsonOutput @local = DString;

fn void ser_indent(JsonOutput* out, int indent, int depth) @noinline
{
	if (indent != -1) out.append_char_repeat(' ', (sz)(indent * depth));
}

fn void ser_kv(JsonOutput* out, String key, int indent, int depth) @noinline
{
	ser_indent(out, indent, depth);
	out.append_char('"');
	out.append(key);
	out.append("\": ");
}

fn void ser_comma(JsonOutput* out, int indent) @noinline
{
	out.append_char(',');
	if (indent != -1) out.append_char('\n');
}

fn void ser_str(JsonOutput* out, String s) @noinline
{
	out.append_char('"');
	foreach (char c : s)
	{
		switch (c)
		{
			case '"': out.append("\\\"");
			case '\\': out.append("\\\\");
			case '\n': out.append("\\n");
			case '\r': out.append("\\r");
			case '\t': out.append("\\t");
			default: out.append_char(c);
		}
	}
	out.append_char('"');
}

fn void JsonOutput.start_obj(&self, int indent) @noinline
{
	self.append_char('{');
	if (indent != -1) self.append_char('\n');
}

fn void JsonOutput.end_obj(&self, int indent, int depth) @noinline
{
	if (self.char_at(self.len() - 2) == ',') self.chop(self.len() - 2);
	if (indent != -1) self.append_char('\n');
	ser_indent(self, indent, depth);
	self.append_char('}');
}

macro void JsonOutput.ser_entry(&self, String key, item, int indent, int depth)
{
	ser_kv(self, key, indent, depth);
	serialize(self, item, indent, depth);
	ser_comma(self, indent);
}

macro void serialize(JsonOutput* output, item, int indent, int depth) @local
{
	$switch :
		$case $defined(Nullable{Node} x = item):
			if (try v = item.get())
			{
				node_serialize(v, output, indent, depth);
			}
			else
			{
				output.append("null");
			}

		$case $Typeof(item) == Node*:
			node_serialize((Node*)item, output, indent, depth);

		$case $Typeof(item)::kind == BITSTRUCT:
			output.start_obj(indent);
			$foreach $m : $Typeof(item)::members:
				$if $Typeof(item.$m) == bool:
					if (item.$m) output.ser_entry($m.name, item.$m, indent, depth + 1);
				$else
					output.ser_entry($m.name, item.$m, indent, depth + 1);
				$endif
			$endforeach
			output.end_obj(indent, depth);

		$case $Typeof(item) == Ident*:
			if (item == null)
			{
				output.append("null");
			}
			else
			{
				ser_str(output, item.text);
			}

		$case $Typeof(item) == Type*:
			if (item == null)
			{
				output.append("null");
			}
			else
			{
				ser_str(output, item.name);
			}

		$case $Typeof(item) == LiteralExpr* ||| $Typeof(item) == LiteralExpr:
			output.start_obj(indent);
			output.ser_entry("literal_kind", item.literal_kind, indent, depth + 1);
			switch (item.literal_kind)
			{
				case INT_LITERAL:    output.ser_entry("value", item.integer, indent, depth + 1);
				case REAL_LITERAL:   output.ser_entry("value", item.real, indent, depth + 1);
				case STRING_LITERAL: output.ser_entry("value", item.string, indent, depth + 1);
				case BYTES_LITERAL:  output.ser_entry("value", item.bytes, indent, depth + 1);
				case BOOL_LITERAL:   output.ser_entry("value", item.boolean, indent, depth + 1);
				case NULL_LITERAL:   ser_kv(output, "value", indent, depth + 1); output.append("null"); ser_comma(output, indent);
			}
			output.end_obj(indent, depth);

		$case $Typeof(item) == TypeExpr* ||| $Typeof(item) == TypeExpr:
			output.start_obj(indent);
			output.ser_entry("type_kind", item.type_kind, indent, depth + 1);
			output.ser_entry("optional", item.optional, indent, depth + 1);
			switch (item.type_kind)
			{
				case TYPE_IDENTIFIER:
					output.ser_entry("unresolved", item.unresolved, indent, depth + 1);
				case TYPE_POINTER:
				case TYPE_SLICE:
					output.ser_entry("modify", item.modify, indent, depth + 1);
				case TYPE_ARRAY:
				case TYPE_VECTOR:
					output.ser_entry("array", item.array, indent, depth + 1);
				case TYPE_GENERIC:
					output.ser_entry("generic", item.generic, indent, depth + 1);
				case TYPE_TYPEOF:
				case TYPE_TYPEFROM:
					output.ser_entry("expr", item.expr, indent, depth + 1);
				case TYPE_FUNCTION:
					output.ser_entry("func", item.func, indent, depth + 1);
			}
			output.end_obj(indent, depth);

		$case $Typeof(item)::kind == POINTER &&& $Typeof(*item)::kind == STRUCT:
			if (item == null)
			{
				output.append("null");
			}
			else
			{
				output.start_obj(indent);
				$foreach $m : $Typeof(*item)::members:
					output.ser_entry($m.name, item.$m, indent, depth + 1);
				$endforeach
				output.end_obj(indent, depth);
			}

		$case $Typeof(item)::kind == STRUCT:
			output.start_obj(indent);
			$foreach $m : $Typeof(item)::members:
				output.ser_entry($m.name, item.$m, indent, depth + 1);
			$endforeach
			output.end_obj(indent, depth);

		$case $Typeof(item) == Ident:
			ser_str(output, item.text);

		$case $Typeof(item) == String:
			ser_str(output, item);

		$case $defined(item[0]) &&& $defined(lengthof(item)):
			sz len = lengthof(item);
			if (len == 0) { output.append("[]"); return; }
			output.append_char('[');
			if (indent != -1) output.append_char('\n');
			foreach (i, el : item)
			{
				ser_indent(output, indent, depth + 1);
				$if $Typeof(el) == Node*:
					node_serialize(el, output, indent, depth);
				$else
					serialize(output, el, indent, depth + 1);
				$endif
				if (i < len - 1) output.append_char(',');
				if (indent != -1) output.append_char('\n');
			}
			ser_indent(output, indent, depth);
			output.append_char(']');

		$default:
			output.appendf(`"%s"`, item);
	$endswitch
}

macro void ser_node_payload(JsonOutput* output, Node* self, $Type, int indent, int depth) @local
{
	output.ser_entry($Type::name, (($Type*)self), indent, depth);
}

fn void node_serialize(Node* self, JsonOutput* output, int indent, int depth) @noinline @local
{
	if (self == null) { output.append("null"); return; }

	output.start_obj(indent);
	output.ser_entry("id", self.id, indent, depth + 1);
	output.ser_entry("kind", self.kind, indent, depth + 1);
	output.ser_entry("visibility", self.visibility, indent, depth + 1);
	output.ser_entry("flags", self.flags, indent, depth + 1);
	output.ser_entry("range.start", self.range.start, indent, depth + 1);
	output.ser_entry("range.end", self.range.end, indent, depth + 1);

	var $sw = "switch (self.kind) {";
	$foreach $m : NodeKind::values:
		$sw +++= @sprintf(`case %s: ser_node_payload(output, self, %s, indent, depth + 1);`, $m.description, @str_pascalcase($m.description));
	$endforeach
	$sw +++= "default: }";
	$expand($sw);

	output.end_obj(indent, depth);
}

fn String Node.serialize(&self, Allocator allocator = tmem, int indent = -1)
{
	JsonOutput output;
	output = output.init(allocator);
	node_serialize(self, &output, indent, 0);
	return output.str_view();
}