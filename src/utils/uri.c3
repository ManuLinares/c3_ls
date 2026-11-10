module uri;
import std::io, std::core::ascii;

faultdef
INVALID_SYNTAX,
UNSUPPORTED_SCHEME,
MALFORMED_HEX;

struct Uri (Printable)
{
	String scheme;
	String path;
	Allocator allocator;
}

fn void Uri.free(&self)
{
	self.scheme.free(self.allocator);
	self.path.free(self.allocator);
}

fn sz? Uri.to_format(&self, Formatter* formatter) @dynamic
{
	if (self.path.starts_with("/"))
	{
		return formatter.printf("%s://%s", self.scheme, self.path);
	}
	return formatter.printf("%s:///%s", self.scheme, self.path);
}

fn bool Uri.equal(self, Uri other) @operator(==)
{
	return self.scheme == other.scheme && self.path == other.path;
}

<*
	Parses a file URI (e.g., file:///home/user/code/main.c3 or file:///C:/project/main.c3)
	@return? INVALID_SYNTAX, UNSUPPORTED_SCHEME, MALFORMED_HEX
*>
fn Uri? parse(Allocator allocator, String raw_uri) => @pool()
{
	sz scheme_bound = raw_uri.index_of("://")!;
	if (scheme_bound == 0) return INVALID_SYNTAX~;

	String scheme = raw_uri[:scheme_bound];
	if (scheme != "file")
	{
		log::error("unhandleable URI scheme: %s", scheme);
		return UNSUPPORTED_SCHEME~;
	}

	String remaining_path = raw_uri[scheme_bound + 3..];

	$if env::WIN32:
		if (remaining_path.starts_with("/") && remaining_path.len >= 3 && remaining_path[2] == ':')
		{
			remaining_path = remaining_path[1..];
		}
		else if (remaining_path.starts_with("/") && remaining_path.len >= 5 && (remaining_path[2..4] == "%3A" || remaining_path[2..4] == "%3a"))
		{
			remaining_path = remaining_path[1..];
		}
	$endif
	// Decode percent-encoded characters
	char[] decoded = mem::temp_array(char, remaining_path.len);
	sz write_idx = 0;

	for (sz i = 0; i < remaining_path.len;)
	{
		if (remaining_path[i] == '%' && i + 2 < remaining_path.len)
		{
			char h1 = remaining_path[i + 1];
			char h2 = remaining_path[i + 2];

			if (!h1.is_xdigit() || !h2.is_xdigit())
			{
				return MALFORMED_HEX~;
			}

			decoded[write_idx++] = (char)((char.from_hex(h1) << 4) | char.from_hex(h2));
			i += 3;
		}
		else
		{
			decoded[write_idx++] = remaining_path[i];
			i++;
		}
	}

	return {
		.scheme = scheme.copy(allocator),
		.path = normalize_path(allocator, (String)decoded[:write_idx]),
		.allocator = allocator
	};
}

<*
 Converts `native_path` to the form used for file keys: '/' separators and, on Windows, an uppercase drive letter.
*>
fn String normalize_path(Allocator allocator, String native_path)
{
	String path = native_path.copy(allocator);
	foreach (&c : path)
	{
		if (*c == '\\') *c = '/';
	}
	$if env::WIN32:
		if (path.len >= 2 && path[0].is_lower() && path[1] == ':') path[0] = path[0].to_upper();
	$endif
	return path;
}

fn Uri from_file_path(Allocator allocator, String native_path)
{
	return {
		.scheme = "file".copy(allocator),
		.path = normalize_path(allocator, native_path),
		.allocator = allocator
	};
}

fn String Uri.to_raw_string(&self, Allocator output_allocator)
{
	if (self.path.starts_with("/"))
	{
		return string::format(output_allocator, "%s://%s", self.scheme, self.path);
	}
	return string::format(output_allocator, "%s:///%s", self.scheme, self.path);
}
