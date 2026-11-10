module lsp::parent_process_test @test;

import lsp::server;
import std::os, std::os::process;

fn void own_process_is_alive()
{
	$if env::WIN32:
		int pid = (int)win32::getCurrentProcessId();
	$else
		int pid = posix::getpid();
	$endif
	assert(server::is_process_alive(pid));
}

fn void missing_process_is_not_alive()
{
	assert(!server::is_process_alive(0x7FFFFFF0));
}

fn void exited_child_is_not_alive() @feat(POSIX)
{
	Process child = process::spawn({ "sh", "-c", "exit 0" })!!;
	int pid = (int)child.child;
	assert(server::is_process_alive(pid));
	child.join()!!;
	assert(!server::is_process_alive(pid));
}
