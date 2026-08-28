module lsp::translator_test @test;

import lsp::translator;
import lsp;
import std::io;

fn void test_decode_did_open()
{
	String body = `{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test.c3","languageId":"c3","version":1,"text":"module foo;"}}}`;
	IoDecodeResult res = translator::decode(mem, body)!!;
	defer res.message.free();

	assert(res.message.method == DID_OPEN);
	assert(res.message.params.did_open.document.uri == "file:///test.c3");
	assert(res.message.params.did_open.document.language_id == "c3");
	assert(res.message.params.did_open.document.version == 1);
	assert(res.message.params.did_open.document.text == "module foo;");
}

fn void test_decode_did_change()
{
	String body = `{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///test.c3","version":2},"contentChanges":[{"text":"module bar;"}]}}`;
	IoDecodeResult res = translator::decode(mem, body)!!;
	defer res.message.free();

	assert(res.message.method == DID_CHANGE);
	assert(res.message.params.did_change.document.uri == "file:///test.c3");
	assert(res.message.params.did_change.document.version == 2);
	assert(res.message.params.did_change.content_changes.len == 1);
	assert(res.message.params.did_change.content_changes[0].text == "module bar;");
}

fn void test_decode_did_close()
{
	String body = `{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///test.c3"}}}`;
	IoDecodeResult res = translator::decode(mem, body)!!;
	defer res.message.free();

	assert(res.message.method == DID_CLOSE);
	assert(res.message.params.did_close.document.uri == "file:///test.c3");
}

fn void test_decode_hover()
{
	String body = `{"jsonrpc":"2.0","id":10,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///test.c3"},"position":{"line":5,"character":12}}}`;
	IoDecodeResult res = translator::decode(mem, body)!!;
	defer res.message.free();

	assert(res.message.method == HOVER);
	assert(res.message.has_id);
	assert(res.message.id == 10);
	assert(res.message.params.hover.document.uri == "file:///test.c3");
	assert(res.message.params.hover.position.line == 5);
	assert(res.message.params.hover.position.character == 12);
}

fn void test_decode_definition()
{
	String body = `{"jsonrpc":"2.0","id":11,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///test.c3"},"position":{"line":2,"character":4}}}`;
	IoDecodeResult res = translator::decode(mem, body)!!;
	defer res.message.free();

	assert(res.message.method == DEFINITION);
	assert(res.message.has_id);
	assert(res.message.id == 11);
	assert(res.message.params.definition.document.uri == "file:///test.c3");
	assert(res.message.params.definition.position.line == 2);
	assert(res.message.params.definition.position.character == 4);
}

fn void test_decode_completion()
{
	String body = `{"jsonrpc":"2.0","id":12,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///test.c3"},"position":{"line":7,"character":1}}}`;
	IoDecodeResult res = translator::decode(mem, body)!!;
	defer res.message.free();

	assert(res.message.method == COMPLETION);
	assert(res.message.has_id);
	assert(res.message.id == 12);
	assert(res.message.params.completion.text_document.uri == "file:///test.c3");
	assert(res.message.params.completion.position.line == 7);
	assert(res.message.params.completion.position.character == 1);
}

fn void test_decode_signature_help()
{
	String body = `{"jsonrpc":"2.0","id":13,"method":"textDocument/signatureHelp","params":{"textDocument":{"uri":"file:///test.c3"},"position":{"line":8,"character":15}}}`;
	IoDecodeResult res = translator::decode(mem, body)!!;
	defer res.message.free();

	assert(res.message.method == HELP);
	assert(res.message.has_id);
	assert(res.message.id == 13);
	assert(res.message.params.signature_help.text_document.uri == "file:///test.c3");
	assert(res.message.params.signature_help.position.line == 8);
	assert(res.message.params.signature_help.position.character == 15);
}

fn void test_decode_references()
{
	String body = `{"jsonrpc":"2.0","id":14,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///test.c3"},"position":{"line":3,"character":8},"context":{"includeDeclaration":true}}}`;
	IoDecodeResult res = translator::decode(mem, body)!!;
	defer res.message.free();

	assert(res.message.method == REFERENCES);
	assert(res.message.has_id);
	assert(res.message.id == 14);
	assert(res.message.params.references.text_document.uri == "file:///test.c3");
	assert(res.message.params.references.context.includeDeclaration == true);
}

fn void test_decode_rename()
{
	String body = `{"jsonrpc":"2.0","id":15,"method":"textDocument/rename","params":{"textDocument":{"uri":"file:///test.c3"},"position":{"line":4,"character":6},"newName":"renamed_var"}}`;
	IoDecodeResult res = translator::decode(mem, body)!!;
	defer res.message.free();

	assert(res.message.method == RENAME);
	assert(res.message.has_id);
	assert(res.message.id == 15);
	assert(res.message.params.rename.text_document.uri == "file:///test.c3");
	assert(res.message.params.rename.newName == "renamed_var");
}

fn void test_decode_semantic_tokens()
{
	String body = `{"jsonrpc":"2.0","id":16,"method":"textDocument/semanticTokens/full","params":{"textDocument":{"uri":"file:///test.c3"}}}`;
	IoDecodeResult res = translator::decode(mem, body)!!;
	defer res.message.free();

	assert(res.message.method == FULL);
	assert(res.message.has_id);
	assert(res.message.id == 16);
	assert(res.message.params.semantic_tokens.text_document.uri == "file:///test.c3");
}

fn void test_decode_completion_resolve_with_documentation()
{
	String body = `{"jsonrpc":"2.0","id":17,"method":"completionItem/resolve","params":{"label":"size","kind":10,"documentation":{"kind":"markdown","value":"Size in bytes"}}}`;
	IoDecodeResult res = translator::decode(mem, body)!!;
	defer res.message.free();

	assert(res.message.method == COMPLETION_RESOLVE);
	assert(res.message.params.completion_resolve.item.label == "size");
	assert(res.message.params.completion_resolve.item.documentation.kind == "markdown");
	assert(res.message.params.completion_resolve.item.documentation.value == "Size in bytes");
}
