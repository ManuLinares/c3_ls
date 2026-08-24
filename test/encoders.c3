// test/encoders.c3
module lsp::encoders_test @test;

import lsp::translator;
import lsp;
import lsp::server;

import std::io;

fn void test_encode_initialize_response()
{
	LspInitializeResponse resp = {
		.jsonrpc = "2.0",
		.id = 1,
		.result = {
			.capabilities = {
				.textDocumentSync = { .openClose = true, .change = FULL },
				.hoverProvider = true,
				.definitionProvider = true,
				.signatureHelpProvider = { .triggerCharacters = { "(", "," } },
				.referencesProvider = true,
				.renameProvider = { .prepareProvider = true },
				.semanticTokensProvider = { .full = true }
			},
			.serverInfo = { .name = "c3_ls", .version = "0.1.0" }
		}
	};
	String encoded = translator::encode(resp, tmem);
	assert(encoded.starts_with("Content-Length:"));
	assert(encoded.contains(`"jsonrpc":"2.0"`));
	assert(encoded.contains(`"name":"c3_ls"`));
	assert(encoded.contains(`"hoverProvider":true`));
	assert(encoded.contains(`"definitionProvider":true`));
	assert(encoded.contains(`"signatureHelpProvider"`));
	assert(encoded.contains(`"referencesProvider":true`));
	assert(encoded.contains(`"renameProvider"`));
	assert(encoded.contains(`"semanticTokensProvider"`));
}

fn void test_encode_hover_response()
{
	LspHoverResponse resp = {
		.jsonrpc = "2.0",
		.id = 2,
		.result = {
			.contents = { .kind = MARKDOWN, .value = "```c3\nint x\n```" }
		}
	};
	String encoded = translator::encode(resp, tmem);
	assert(encoded.starts_with("Content-Length:"));
	assert(encoded.contains(`"kind":"markdown"`));
	assert(encoded.contains(`"value":"`));
}

fn void test_encode_completion_response()
{
	CompletionItem[1] items = {
		{ .label = "my_func", .kind = FUNCTION, .detail = "fn void()" }
	};
	LspCompletionResponse resp = {
		.jsonrpc = "2.0",
		.id = 3,
		.result = {
			.isIncomplete = false,
			.items = &items
		}
	};
	String encoded = translator::encode(resp, tmem);
	assert(encoded.starts_with("Content-Length:"));
	assert(encoded.contains(`"label":"my_func"`));
	assert(encoded.contains(`"isIncomplete":false`));
}

fn void test_encode_goto_definition_response()
{
	LspLocation[1] locs = {
		{
			.uri = "file:///test.c3",
			.range = {
				.start = { .line = 10, .character = 4 },
				.end = { .line = 10, .character = 12 }
			}
		}
	};
	LspGoToDefinitionResponse resp = {
		.jsonrpc = "2.0",
		.id = 4,
		.result = &locs
	};
	String encoded = translator::encode(resp, tmem);
	assert(encoded.starts_with("Content-Length:"));
	assert(encoded.contains(`"uri":"file:///test.c3"`));
	assert(encoded.contains(`"line":10`));
}

fn void test_encode_signature_help_response()
{
	ParameterInformation[2] params = {
		{ .label = "int x" },
		{ .label = "int y" }
	};
	SignatureInformation[1] sigs = {
		{
			.label = "fn void draw(int x, int y)",
			.parameters = &params,
			.activeParameter = 1
		}
	};
	LspSignatureHelpResponse resp = {
		.jsonrpc = "2.0",
		.id = 5,
		.result = {
			.signatures = &sigs,
			.activeSignature = 0,
			.activeParameter = 1
		}
	};
	String encoded = translator::encode(resp, tmem);
	assert(encoded.starts_with("Content-Length:"));
	assert(encoded.contains(`"activeParameter":1`));
	assert(encoded.contains(`"label":"fn void draw(int x, int y)"`));
}

fn void test_encode_references_response()
{
	LspLocation[1] locs = {
		{
			.uri = "file:///app.c3",
			.range = { .start = { .line = 5, .character = 2 }, .end = { .line = 5, .character = 10 } }
		}
	};
	LspReferencesResponse resp = {
		.jsonrpc = "2.0",
		.id = 6,
		.result = &locs
	};
	String encoded = translator::encode(resp, tmem);
	assert(encoded.starts_with("Content-Length:"));
	assert(encoded.contains(`"file:///app.c3"`));
}

fn void test_encode_rename_response()
{
	TextEdit[1] edits = {
		{ .range = { .start = { .line = 2, .character = 4 }, .end = { .line = 2, .character = 9 } }, .newText = "updated_name" }
	};
	TextDocumentEdit[1] doc_edits = {
		{
			.textDocument = { .uri = "file:///app.c3", .version = 1 },
			.edits = &edits
		}
	};
	LspRenameResponse resp = {
		.jsonrpc = "2.0",
		.id = 7,
		.result = { .documentChanges = &doc_edits }
	};
	String encoded = translator::encode(resp, tmem);
	assert(encoded.starts_with("Content-Length:"));
	assert(encoded.contains(`"newText":"updated_name"`));
}

fn void test_encode_semantic_tokens_response()
{
	uint[5] data = { 0, 0, 6, 15, 0 };
	LspSemanticTokensResponse resp = {
		.jsonrpc = "2.0",
		.id = 8,
		.result = { .data = &data }
	};
	String encoded = translator::encode(resp, tmem);
	assert(encoded.starts_with("Content-Length:"));
	assert(encoded.contains(`"data":[0,0,6,15,0]`));
}

fn void test_encode_publish_diagnostics()
{
	LspDiagnostic[1] diags = {
		{
			.range = { .start = { .line = 1, .character = 0 }, .end = { .line = 1, .character = 5 } },
			.severity = 1,
			.message = "Type error",
			.source = "c3-analyzer"
		}
	};
	LspPublishDiagnosticsNotification notif = {
		.jsonrpc = "2.0",
		.method = "textDocument/publishDiagnostics",
		.params = {
			.uri = "file:///main.c3",
			.diagnostics = &diags
		}
	};
	String encoded = translator::encode(notif, tmem);
	assert(encoded.starts_with("Content-Length:"));
	assert(encoded.contains(`"method":"textDocument/publishDiagnostics"`));
	assert(encoded.contains(`"message":"Type error"`));
}