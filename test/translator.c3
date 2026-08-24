module lsp::translator @test;

import std::io;
import lsp;
import lsp::server;

fn void encode_message()
{
	LspShutdownResponse response = {
		.jsonrpc = "2.0",
		.id = 1,
	};
	String actual = translator::encode(response, tmem);
	assert(actual.contains(`"jsonrpc":"2.0"`));
	assert(actual.contains(`"id":1`));
	assert(actual.starts_with("Content-Length:"));
}

fn void decode_message()
{
	String body = `{"jsonrpc":"2.0","method":"initialize","id":42,"params":{"processId":123}}`;
	IoDecodeResult actual = translator::decode(mem, body)!!;
	defer actual.message.free();

	assert(actual.message.rpc == "2.0");
	assert(actual.message.method == INITIALIZE);
	assert(actual.message.has_id);
	assert(actual.message.id == 42);
	assert(actual.message.params.initialize.process_id == 123);
}
