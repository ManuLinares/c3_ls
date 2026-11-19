module analyzer::core::arch;

import analyzer::core;
import analyzer::core::os;
import std::collections::list;

fn ArchType current()
{
	return env::ARCH_TYPE;
}

<*
 get the size of a pointer in bytes for the given architecture
*>
fn char ptr_size(ArchType arch)
{
	switch (arch)
	{
		case X86_64:
		case AARCH64:
		case RISCV64:
		case WASM64:
			return 8;
		case X86:
		case ARM:
		case WASM32:
			return 4;
		default:
			return 0;
	}
}

<*
 Features c3c enables for a default build for `target`, as in `compiler.c`:
 the OS and architecture ones, LIBC, endianness, SAFE_MODE and DEBUG_SYMBOLS.
*>
fn String[] features(Allocator allocator, Target target)
{
	List{String} out;
	out.init(allocator);
	out.push_all({ "LIBC", "SAFE_MODE", "DEBUG_SYMBOLS" });
	switch (target.os)
	{
		case FREEBSD: out.push_all({ "POSIX", "BSD", "FREEBSD" });
		case NETBSD: out.push_all({ "POSIX", "BSD", "NETBSD" });
		case OPENBSD: out.push_all({ "POSIX", "BSD", "OPENBSD" });
		case LINUX: out.push_all({ "POSIX", "LINUX" });
		case MACOS: out.push_all({ "POSIX", "DARWIN", "MACOS" });
		case IOS: out.push_all({ "POSIX", "DARWIN", "IOS" });
		case TVOS: out.push_all({ "POSIX", "DARWIN", "TVOS" });
		case WATCHOS: out.push_all({ "POSIX", "DARWIN", "WATCHOS" });
		case ANDROID: out.push_all({ "POSIX", "ANDROID" });
		case EMSCRIPTEN: out.push_all({ "POSIX", "EMSCRIPTEN" });
		case WIN32: out.push("WIN32");
		case WASI: out.push("WASI");
		default: break;
	}
	switch (target.arch)
	{
		case ARM: out.push("ARM");
		case ARMB: out.push("ARMB");
		case AARCH64: out.push("AARCH64");
		case RISCV32: out.push("RISCV32");
		case RISCV64: out.push("RISCV64");
		case X86: out.push("X86");
		case X86_64: out.push("X86_64");
		case WASM32: out.push_all({ "WASM", "WASM32" });
		case WASM64: out.push_all({ "WASM", "WASM64" });
		case XTENSA: out.push("XTENSA");
		default: break;
	}
	switch (target.arch)
	{
		case ARMB:
		case AARCH64_BE:
		case MIPS:
		case MIPS64:
		case PPC:
		case PPC64:
		case SPARC:
		case SPARCV9:
		case SYSTEMZ:
		case THUMBEB:
			out.push("BIG_ENDIAN");
		default:
			out.push("LITTLE_ENDIAN");
	}
	switch (ptr_size(target.arch))
	{
		case 4: out.push("ARCH_32_BIT");
		case 8: out.push("ARCH_64_BIT");
		default: break;
	}
	return out.array_view();
}

fn TargetLayout get_platform_layout(OsType os, ArchType arch)
{
	TargetLayout layout;
	for (char i = BitSizes.BITS8.ordinal; i < BitSizes::len; i++)
	{
		AlignData align = os::get_alignment(os, arch, BitSizes::from_ordinal(i).bits);
		layout.integers[i] = align;
		layout.floats[i] = align;
	}
	layout.integers[BitSizes.BIT1] = layout.integers[BitSizes.BITS8];
	layout.floats[BitSizes.BIT1] = layout.floats[BitSizes.BITS8];
	return layout;
}

fn void test_bitsizes() @test
{
	// Test X86_64 Linux (Standard 64-bit ABI)
	TargetLayout layout = get_platform_layout(LINUX, X86_64);

	test::eq(layout.integers[BitSizes.BITS64].align, 8u);
	test::eq(layout.integers[BitSizes.BITS64].pref_align, 8u);
	test::eq(layout.integers[BitSizes.BITS32].align, 4u);
	test::eq(layout.integers[BitSizes.BITS128].align, 16u);
	test::eq(layout.integers[BitSizes.BITS8].align, 1u);
	test::eq(layout.integers[BitSizes.BIT1].align, 1u);
}
