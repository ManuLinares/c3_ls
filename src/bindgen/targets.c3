module lsp::bindgen;

import std;

faultdef UNKNOWN_TARGET;

struct BindgenTarget
{
	String name;
	String triple;
}

<*
 c3c's target names with the clang triples c3c compiles them for (glibc on Linux).
*>
const BindgenTarget[*] TARGETS = {
	{ "android-aarch64", "aarch64-linux-android" },
	{ "android-x86_64", "x86_64-linux-android" },
	{ "elf-aarch64", "aarch64-unknown-elf" },
	{ "elf-riscv32", "riscv32-unknown-elf" },
	{ "elf-riscv64", "riscv64-unknown-elf" },
	{ "elf-x86", "i386-unknown-elf" },
	{ "elf-x64", "x86_64-unknown-elf" },
	{ "elf-xtensa", "xtensa-unknown-elf" },
	{ "elf-avr", "avr-unknown-unknown" },
	{ "freebsd-x86", "i386-unknown-freebsd" },
	{ "freebsd-x64", "x86_64-pc-freebsd" },
	{ "ios-aarch64", "arm64-apple-ios" },
	{ "ios-aarch64-sim", "arm64-apple-ios-simulator" },
	{ "ios-x64-sim", "x86_64-apple-ios-simulator" },
	{ "linux-aarch64", "aarch64-unknown-linux-gnu" },
	{ "linux-riscv32", "riscv32-unknown-linux-gnu" },
	{ "linux-riscv64", "riscv64-unknown-linux-gnu" },
	{ "linux-x86", "i386-unknown-linux" },
	{ "linux-x64", "x86_64-pc-linux-gnu" },
	{ "macos-aarch64", "aarch64-apple-macosx" },
	{ "macos-x64", "x86_64-apple-macosx" },
	{ "mcu-x86", "i386-pc-elfiamcu" },
	{ "mingw-x64", "x86_64-w64-windows-gnu" },
	{ "netbsd-aarch64", "aarch64-unknown-netbsd" },
	{ "netbsd-x86", "i386-unknown-netbsd" },
	{ "netbsd-x64", "x86_64-pc-netbsd" },
	{ "openbsd-x86", "i386-unknown-openbsd" },
	{ "openbsd-x64", "x86_64-pc-openbsd" },
	{ "wasm32", "wasm32-unknown-unknown" },
	{ "wasm64", "wasm64-unknown-unknown" },
	{ "emscripten", "wasm32-unknown-emscripten" },
	{ "windows-aarch64", "aarch64-pc-windows-msvc" },
	{ "windows-x64", "x86_64-pc-windows-msvc" },
};

<*
 The clang triple for a c3c target name.
*>
fn String? target_triple(String name)
{
	foreach (target : TARGETS)
	{
		if (target.name == name) return target.triple;
	}
	return UNKNOWN_TARGET~;
}

<*
 Every c3c target name, one per line.
*>
fn String target_names()
{
	DString out;
	out.tinit();
	foreach (target : TARGETS) out.appendf("  %s\n", target.name);
	return out.str_view();
}

<*
 The MSVC triple for the host architecture, used for Windows headers when no target is given.
*>
fn String host_windows_triple()
{
	return env::AARCH64 ? "aarch64-pc-windows-msvc" : "x86_64-pc-windows-msvc";
}
