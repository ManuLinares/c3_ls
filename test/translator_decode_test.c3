module lsp::translator_decode_test @test;

import lsp;
import lsp::translator;
import std::collections::object;

macro LspMessage decode(String json)
{
	return translator::decode(tmem, json)!!.message;
}

fn void initialize_with_nulls_and_folders()
{
	LspMessage msg = decode(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"rootPath":null,"trace":"verbose","clientInfo":{"name":"vscode","version":"1.0"},"workspaceFolders":[{"uri":"file:///w","name":"w"}],"capabilities":{"textDocument":{"completion":{"completionItem":{"snippetSupport":true}}}}}}`);
	test::eq(msg.method, MessageKind.INITIALIZE);
	test::eq(msg.id, 1);
	assert(msg.has_id);
	InitializeParams p = msg.params.initialize;
	test::eq(p.process_id, 0);
	test::eq(p.root(tmem), "");
	test::eq(p.trace, TraceKind.VERBOSE);
	test::eq(p.client_info.name, "vscode");
	test::eq(p.workspace_folders.len, 1);
	test::eq(p.workspace_folders[0].uri, "file:///w");
}

fn void initialize_root_path_fallback_and_option_spellings()
{
	InitializeParams p = decode(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootPath":"/tmp/ws","initializationOptions":{"compilerPath":"/bin/c3c","stdlib-path":"/lib/std"}}}`).params.initialize;
	test::eq(p.root(tmem), "file:///tmp/ws");
	test::eq(p.options().compiler_path, "/bin/c3c");
	test::eq(p.options().stdlib_path, "/lib/std");
	test::eq(decode(`{"id":1,"method":"initialize","params":{"initializationOptions":{"compiler_path":"/c"}}}`).params.initialize.options().compiler_path, "/c");
}

fn void string_id_is_not_an_int_id()
{
	LspMessage msg = decode(`{"jsonrpc":"2.0","id":"a1","method":"shutdown"}`);
	assert(!msg.has_id);
	test::eq(msg.method, MessageKind.SHUTDOWN);
}

fn void text_document_notifications()
{
	DidOpenParams open = decode(`{"method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.c3","languageId":"c3","version":3,"text":"module a;"}}}`).params.did_open;
	test::eq(open.document.uri, "file:///a.c3");
	test::eq(open.document.language_id, "c3");
	test::eq(open.document.version, 3);
	test::eq(open.document.text, "module a;");

	DidChangeParams change = decode(`{"method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.c3","version":4},"contentChanges":[{"text":"module b;"}]}}`).params.did_change;
	test::eq(change.document.version, 4);
	test::eq(change.content_changes[0].text, "module b;");

	test::eq(decode(`{"method":"textDocument/didSave","params":{"textDocument":{"uri":"file:///s.c3"}}}`).params.did_save.document.uri, "file:///s.c3");
	test::eq(decode(`{"method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///c.c3"}}}`).params.did_close.document.uri, "file:///c.c3");
}

fn void position_requests()
{
	PrepareRenameParams prep = decode(`{"id":2,"method":"textDocument/prepareRename","params":{"textDocument":{"uri":"file:///p.c3"},"position":{"line":5,"character":7}}}`).params.prepare_rename;
	test::eq(prep.text_document.uri, "file:///p.c3");
	assert(prep.position.line == 5 && prep.position.character == 7);

	CompletionParams comp = decode(`{"id":3,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///c.c3"},"position":{"line":1,"character":2},"context":{"triggerKind":2,"triggerCharacter":"."}}}`).params.completion;
	test::eq(comp.context.triggerCharacter, ".");
}

fn void document_requests()
{
	test::eq(decode(`{"id":4,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///d.c3"}}}`).params.document_symbol.text_document.uri, "file:///d.c3");
	test::eq(decode(`{"id":5,"method":"workspace/symbol","params":{"query":"Foo"}}`).params.workspace_symbol.query, "Foo");
	test::eq(decode(`{"id":6,"method":"textDocument/foldingRange","params":{"textDocument":{"uri":"file:///f.c3"}}}`).params.folding_range.text_document.uri, "file:///f.c3");
	InlayHintParams hints = decode(`{"id":7,"method":"textDocument/inlayHint","params":{"textDocument":{"uri":"file:///i.c3"},"range":{"start":{"line":0,"character":0},"end":{"line":9,"character":1}}}}`).params.inlay_hint;
	assert(hints.range.end.line == 9);
}

fn void formatting_follows_editor_options()
{
	DocumentFormattingParams fmt = decode(`{"id":8,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///x.c3"},"options":{"tabSize":2,"insertSpaces":true}}}`).params.formatting;
	test::eq(fmt.text_document.uri, "file:///x.c3");
	assert(fmt.options.tab_size == 2);
	assert(fmt.options.insert_spaces);
	assert(!fmt.options.insert_final_newline);

	DocumentRangeFormattingParams range_fmt = decode(`{"id":9,"method":"textDocument/rangeFormatting","params":{"textDocument":{"uri":"file:///x.c3"},"range":{"start":{"line":1,"character":0},"end":{"line":3,"character":0}},"options":{"tabSize":4,"insertSpaces":false,"insertFinalNewline":true}}}`).params.range_formatting;
	assert(range_fmt.range.start.line == 1);
	assert(range_fmt.options.tab_size == 4);
	assert(range_fmt.options.insert_final_newline);
}

fn void code_action_and_commands()
{
	CodeActionParams action = decode(`{"id":10,"method":"textDocument/codeAction","params":{"textDocument":{"uri":"file:///a.c3"},"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":5}},"context":{"diagnostics":[{"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":5}},"severity":1,"code":"E1","source":"c3c","message":"oops"}],"triggerKind":1}}}`).params.code_action;
	test::eq(action.context.diagnostics.len, 1);
	test::eq(action.context.diagnostics[0].message, "oops");
	test::eq(action.context.diagnostics[0].severity, 1);

	ExecuteCommandParams exec = decode(`{"id":11,"method":"workspace/executeCommand","params":{"command":"c3.do","arguments":["a","b"]}}`).params.execute_command;
	test::eq(exec.command, "c3.do");
	test::eq(exec.arguments.len, 2);
	test::eq(exec.arguments[1], "b");

	DidChangeWatchedFilesParams watched = decode(`{"method":"workspace/didChangeWatchedFiles","params":{"changes":[{"uri":"file:///w.c3","type":2}]}}`).params.did_change_watched;
	test::eq(watched.changes[0].uri, "file:///w.c3");
	test::eq(watched.changes[0].type, 2);
}

fn void completion_resolve_keeps_documentation_and_edit()
{
	CompletionItem item = decode(`{"id":12,"method":"completionItem/resolve","params":{"label":"@mac","kind":3,"documentation":{"kind":"markdown","value":"doc"},"textEdit":{"range":{"start":{"line":2,"character":1},"end":{"line":2,"character":4}},"newText":"lala::@mac();"}}}`).params.completion_resolve.item;
	test::eq(item.label, "@mac");
	test::eq(item.documentation.value, "doc");
	test::eq(item.textEdit.newText, "lala::@mac();");
}

fn void heap_decoded_message_frees()
{
	LspMessage msg = translator::decode(mem, `{"id":13,"method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.c3","version":1},"contentChanges":[{"text":"x"}]}}`)!!.message;
	msg.free();
}
