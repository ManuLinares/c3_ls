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

module lsp::parent_process_test::security @feat(WIN32) @link("advapi32");

import std::os;

extern fn Win32_DWORD get_process_id(Win32_HANDLE process) @cname("GetProcessId");
extern fn Win32_BOOL initialize_acl(void* acl, Win32_DWORD len, Win32_DWORD revision) @cname("InitializeAcl");
extern fn Win32_DWORD set_security_info(Win32_HANDLE handle, CInt object_type, Win32_DWORD info, void* owner, void* group, void* dacl, void* sacl) @cname("SetSecurityInfo");

const CInt SE_KERNEL_OBJECT = 6;
const Win32_DWORD DACL_SECURITY_INFORMATION = 4;
const Win32_DWORD ACL_REVISION = 2;

module lsp::parent_process_test::win32 @test @feat(WIN32);

import lsp::server, lsp::parent_process_test::security;
import std::os, std::os::process;

fn void inaccessible_process_is_alive()
{
	Process child = process::spawn({ "cmd", "/c", "ping -n 30 127.0.0.1 >nul" })!!;
	defer (void)child.terminate();
	char[64] empty_acl;
	assert(security::initialize_acl(&empty_acl, empty_acl.len, security::ACL_REVISION));
	assert(security::set_security_info(child.hProcess, security::SE_KERNEL_OBJECT, security::DACL_SECURITY_INFORMATION, null, null, &empty_acl, null) == 0);
	assert(server::is_process_alive((int)security::get_process_id(child.hProcess)));
}
