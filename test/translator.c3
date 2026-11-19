module lsp::translator @test;

import std::collections::object;
import std::io;
import lsp;
import lsp::server;

fn void encode_message()
{
	LspResponse{Object*} response = {
		.jsonrpc = "2.0",
		.id = object::new_int(tmem, 1),
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
	assert(actual.message.id);
	assert(actual.message.id.i == 42);
	assert(actual.message.params.initialize.process_id.value()!! == 123);
}

fn void string_id_is_echoed()
{
	String body = `{"jsonrpc":"2.0","method":"shutdown","id":"req-7"}`;
	IoDecodeResult actual = translator::decode(mem, body)!!;
	defer actual.message.free();
	assert(actual.message.id && actual.message.id.is_string() && actual.message.id.s == "req-7");

	LspResponse{Object*} response = { .jsonrpc = "2.0", .id = actual.message.id };
	assert(translator::encode(response, tmem).contains(`"id":"req-7"`));
}
