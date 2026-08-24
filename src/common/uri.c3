// src/common/uri.c3
module uri;

import std::io;
import std::core::ascii;

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
	$if env::WIN32:
		return formatter.printf("%s:///%s", self.scheme, self.path);
	$else
		return formatter.printf("%s://%s", self.scheme, self.path);
	$endif
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
		remaining_path = remaining_path.trim_left("/");
		// Adjust for Windows authority/drive formatting quirks ('/C%3A/foo' -> 'C%3A/foo')
		if (remaining_path.starts_with("/") && remaining_path.len >= 4 && remaining_path[2] == '%' && remaining_path[3] == '3')
		{
			remaining_path = remaining_path[1..];
		}
	$endif

	// Decode percent-encoded characters
	char[] decoded = mem::temp_array(char, remaining_path.len);
	sz write_idx = 0;

	for (sz i = 0; i < remaining_path.len; )
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
		else if (remaining_path[i] == '\\')
		{
			decoded[write_idx++] = '/'; 
			i++;
		}
		else
		{
			decoded[write_idx++] = remaining_path[i];
			i++;
		}
	}

	String native_path = (String)decoded[:write_idx];

	$if env::WIN32:
		if (native_path.len >= 2 && native_path[0].is_lower() && native_path[1] == ':')
		{
			native_path[0] = native_path[0].to_upper(); 
		}
	$endif

	return {
		.scheme = scheme.copy(allocator),
		.path = native_path.copy(allocator),
		.allocator = allocator
	};
}

fn Uri from_file_path(Allocator allocator, String native_path)
{
	String cleaned_path = native_path.copy(tmem);
	for (sz i = 0; i < cleaned_path.len; i++)
	{
		if (cleaned_path[i] == '\\')
		{
			cleaned_path[i] = '/';
		}
	}

	$if env::WIN32:
		if (cleaned_path.len >= 2 && cleaned_path[0].is_lower() && cleaned_path[1] == ':')
		{
			cleaned_path[0] = cleaned_path[0].to_upper();
		}
	$endif

	return {
		.scheme = "file".copy(allocator),
		.path = cleaned_path.copy(allocator),
		.allocator = allocator
	};
}

fn String Uri.to_raw_string(&self, Allocator output_allocator)
{
	$if env::WIN32:
		return string::format(output_allocator, "%s:///%s", self.scheme, self.path);
	$else
		return string::format(output_allocator, "%s://%s", self.scheme, self.path);
	$endif
}