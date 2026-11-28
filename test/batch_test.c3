module lsp::batch_test;

import lsp, lsp::server, lsp::analysis::completion, uri, std::collections::list, std::collections::object;

macro LspMessage decoded(String json) => translator::decode(tmem, json)!!.message;

fn void cancel_matches_its_request() @test
{
	LspMessage[3] batch = {
		decoded(`{"jsonrpc":"2.0","id":7,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.c3"},"position":{"line":0,"character":0}}}`),
		decoded(`{"jsonrpc":"2.0","id":"s1","method":"shutdown"}`),
		decoded(`{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":7}}`),
	};
	assert(server::is_cancelled_in(&batch, batch[0].id));
	assert(!server::is_cancelled_in(&batch, batch[1].id));
}

fn void cancel_matches_string_ids() @test
{
	LspMessage[2] batch = {
		decoded(`{"jsonrpc":"2.0","id":"s1","method":"shutdown"}`),
		decoded(`{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":"s1"}}`),
	};
	assert(server::is_cancelled_in(&batch, batch[0].id));
	assert(!server::is_cancelled_in(&batch, object::new_int(tmem, 1)));
}

fn void cancelled_reply_is_an_error() @test
{
	LspErrorResponse resp = { .jsonrpc = "2.0", .id = object::new_int(tmem, 7), .error = { server::REQUEST_CANCELLED, "Request cancelled" } };
	String json = translator::encode(resp, tmem);
	assert(json.contains(`"id":7`) && json.contains(`"code":-32800`), "%s", json);
}

fn void queued_edits_are_analyzed_once_with_the_latest_text() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri u = uri::from_file_path(tmem, "/virtual/batch.c3");
	DocumentUri raw = (DocumentUri)u.to_raw_string(tmem);
	proj.open_file({ .uri = raw, .language_id = "c3", .version = 1, .text = "module app;\nfn void one() {}\n" });
	proj.update();
	proj.change_file({ .document = { .uri = raw, .version = 2 }, .content_changes = (TextDocumentContentChangeEvent[]){ { .text = "module app;\nfn void two() {}\n" } } });
	proj.change_file({ .document = { .uri = raw, .version = 3 }, .content_changes = (TextDocumentContentChangeEvent[]){ { .text = "module app;\nfn void three() {}\nfn void f() { thr }\n" } } });
	assert(proj.process_queue.len() == 2);
	proj.update();
	bool found;
	foreach (item : completion::resolve(&proj, u, { 2, 17 })!!) if (item.label == "three") found = true;
	assert(found);
}

fn void request_before_an_edit_of_its_document_is_superseded() @test
{
	LspMessage[5] batch = {
		decoded(`{"jsonrpc":"2.0","id":1,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///a.c3"},"position":{"line":0,"character":0}}}`),
		decoded(`{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///b.c3"},"position":{"line":0,"character":0}}}`),
		decoded(`{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.c3","version":2},"contentChanges":[{"text":""}]}}`),
		decoded(`{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///a.c3"},"position":{"line":0,"character":0}}}`),
		decoded(`{"jsonrpc":"2.0","id":"s1","method":"shutdown"}`),
	};
	assert(server::is_superseded_in(&batch, 0));
	assert(!server::is_superseded_in(&batch, 1));
	assert(!server::is_superseded_in(&batch, 2));
	assert(!server::is_superseded_in(&batch, 3));
	assert(!server::is_superseded_in(&batch, 4));
}
