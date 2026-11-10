module lsp::server;

import std::thread, std::os, libc;

<*
 How often a POSIX server checks that the editor that started it is alive.
*>
const long PARENT_POLL_MS = 3000;

extern fn Win32_HANDLE open_process(Win32_DWORD access, Win32_BOOL inherit, Win32_DWORD pid) @cname("OpenProcess") @feat(WIN32);
const Win32_DWORD SYNCHRONIZE @feat(WIN32) = 0x00100000;

fn bool is_process_alive(int pid) @feat(!WIN32)
{
	return posix::kill((Pid_t)pid, 0) == 0 || libc::errno() == EPERM;
}

fn bool is_process_alive(int pid) @feat(WIN32)
{
	Win32_HANDLE process = open_process(SYNCHRONIZE, 0, (Win32_DWORD)pid);
	if (!process) return false;
	defer win32::closeHandle(process);
	return win32::waitForSingleObject(process, 0) == win32::WAIT_TIMEOUT;
}

<*
 Exits the server once the editor process `pid`, from `initialize`, has exited, as LSP asks of a
 server whose stdin may outlive its editor.
*>
fn void watch_parent_process(int pid)
{
	Thread watcher;
	if (catch err = watcher.create(&wait_for_parent_exit, (void*)(iptr)pid))
	{
		log::error("Could not watch the editor process %d: %s", pid, err);
		return;
	}
	(void)watcher.detach();
}

fn int wait_for_parent_exit(void* arg) @local
{
	int pid = (int)(iptr)arg;
	$if env::WIN32:
		Win32_HANDLE process = open_process(SYNCHRONIZE, 0, (Win32_DWORD)pid);
		if (process) win32::waitForSingleObject(process, win32::INFINITE);
	$else
		while (is_process_alive(pid)) thread::sleep_ms(PARENT_POLL_MS);
	$endif
	log::info("Editor process %d exited. Terminating process.", pid);
	// The main thread is blocked reading stdin, so `exit` would deadlock flushing it.
	os::fastexit(1);
}
