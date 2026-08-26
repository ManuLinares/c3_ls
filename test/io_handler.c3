module lsp::io_handler @test;
import lsp::translator;
import lsp;

import std::io;

fn void read_message()
{
	io_handler::init();
	defer io_handler::quit();

	LspMessage actual = io_handler::read_string(mem,
	"Content-Length: 51\r\n\r\n" +++ `{"jsonrpc":"2.0","method":"initialize","params":{}}`)
	??
	{
		.method = MessageKind.INITIALIZE
	};
	defer actual.free();
	assert(actual.method == MessageKind.INITIALIZE);
	assert(actual.rpc == "2.0");
}

fn void read_message_compound()
{
	io_handler::init();
	defer io_handler::quit();

	assert(
	@catch(io_handler::read_string(mem, "Content-Length: 51\r\n\r\n"
	+++ `{"jsonrpc":"2.0","met`))
	== translator::INCOMPLETE_JSON
	);
}

fn void read_multiple_messages()
{
	io_handler::init();
	defer io_handler::quit();

	String message1 = "Content-Length: 51\r\n\r\n" +++ `{"jsonrpc":"2.0","method":"initialize","params":{}}`;
	LspMessage actual1 = io_handler::read_string(mem, message1) ??
	{
		.method = UNKNOWN
	};
	assert(actual1.method == MessageKind.INITIALIZE);
	assert(actual1.rpc == "2.0");
	actual1.free();

	String message2 = "Content-Length: 53\r\n\r\n" +++ `{"jsonrpc":"41.52","method":"initialize","params":{}}`;
	LspMessage actual2 = io_handler::read_string(mem, message2) ??
	{
		.method = UNKNOWN
	};
	assert(actual2.method == MessageKind.INITIALIZE);
	assert(actual2.rpc == "41.52");
	actual2.free();
}
