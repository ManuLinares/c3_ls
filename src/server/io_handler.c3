module lsp::io_handler;
import lsp::translator;

import std::core::log;
import std::core::mem;
import std::io;
import std::collections::list;
import std::net::os;
import libc;
import std::os::win32;

extern fn int _setmode(int fd, int mode) @feat(WIN32);

fn void init()
{
	$if env::WIN32:
		_setmode(0, 0x8000);  // stdin -> O_BINARY
		_setmode(1, 0x8000);  // stdout -> O_BINARY
	$endif
}

fn void quit() {}

fn LspMessage? read_string(Allocator allocator, String message)
{
	ByteReader stream;
	stream.init(message);
	return read(allocator, &stream);
}

<*
  Reads a protocol-framed LSP message from stdin.
  @return "LSP message allocated with `allocator`"
  @return? translator::INVALID_MESSAGE, translator::INCOMPLETE_JSON, io::EOF
*>
fn LspMessage? read(Allocator allocator, InStream stream = &stdin_reader)
{
	DString line;
	line.tinit();

	while (true)
	{
		line.clear();
		while (true)
		{
			if (try c = stream.read_byte())
			{
				if (c == '\n') break;
				if (c != '\r') line.append_char(c);
			}
			else
			{
				return io::EOF~;
			}
		}
		if (line.len() > 0) break;
	}

	String s = line.str_view();
	if (!s.contains("Content-Length:")) return translator::INVALID_MESSAGE~;

	sz content_length = 0;
	if (try cl_pos = s.index_of("Content-Length:"))
	{
		content_length = (sz)(s[cl_pos + 15..].trim().to_uint() ?? 0);
	}
	if (content_length == 0) return translator::INVALID_MESSAGE~;
	// Consume remaining headers until hitting the blank separator line
	while (true)
	{
		DString hdr;
		hdr.tinit();
		while (true)
		{
			if (try c = stream.read_byte())
			{
				if (c == '\n') break;
				if (c != '\r') hdr.append_char(c);
			}
			else
			{
				return io::EOF~;
			}
		}
		if (hdr.str_view().len == 0) break;
	}

	char[] body = mem::temp_array(char, content_length);
	sz read_so_far = 0;
	while (read_so_far < content_length)
	{
		sz n = stream.read(body[read_so_far..content_length - 1]) ?? 0;
		if (n == 0)
		{
			return translator::INCOMPLETE_JSON~;
		}
		read_so_far += n;
	}

	String json_payload = (String)body[:content_length];

	IoDecodeResult? decode_result = translator::decode(allocator, json_payload);
	if (catch err = decode_result)
	{
		log::error("LSP decode error caught: %s", err);
		return translator::INVALID_MESSAGE~;
	}

	return decode_result.message;
}

<*
 Stdin read with the OS's own read call: unlike `io::stdin()`, whose libc
 `fread` waits until the whole requested length arrived, a read returns what
 the client has sent so far.
*>
struct RawStdin (InStream)
{
	bool at_end;
}

fn sz? RawStdin.read(&self, char[] bytes) @dynamic
{
	if (self.at_end) return 0;
	$if env::WIN32:
		Win32_DWORD got;
		if (!win32::readFile(win32::getStdHandle(win32::STD_INPUT_HANDLE), bytes.ptr, (Win32_DWORD)bytes.len, &got, null)) got = 0;
		sz n = got;
	$else
		sz n = max(libc::read(0, bytes.ptr, bytes.len), 0);
	$endif
	if (n == 0) self.at_end = true;
	return n;
}

fn char? RawStdin.read_byte(&self) @dynamic
{
	char[1] byte;
	return self.read(&byte)! == 1 ? byte[0] : io::EOF~;
}

RawStdin raw_stdin;
char[65536] stdin_buffer;
ReadBuffer stdin_reader;

<*
 Whether input is waiting: buffered in `stdin_reader`, or sent by the client and not read yet. Does not wait.
*>
fn bool has_pending()
{
	if (stdin_reader.array_view().len) return true;
	$if env::WIN32:
		Win32_DWORD available;
		return win32::peekNamedPipe(win32::getStdHandle(win32::STD_INPUT_HANDLE), null, 0, null, &available, null) && available > 0;
	$else
		Posix_pollfd pfd = { .fd = 0, .events = os::POLLIN };
		return os::poll(&pfd, 1, 0) > 0 && (pfd.revents & os::POLLIN);
	$endif
}

fn void write(String message) @inline
{
	io::print(message);
	io::stdout().flush()!!;
}
