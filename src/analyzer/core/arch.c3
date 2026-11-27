module analyzer::core::arch;

import analyzer::core;
import analyzer::core::os;

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

struct TargetFeatures
{
	OsType os;
	ArchType arch;
	String[] features;
}

<*
 Features c3c 0.8 enables in a default build of each of its targets that
 builds with the stdlib, as `$feat` reports them; one entry per OS and
 architecture.
*>
const TargetFeatures[*] C3C_TARGETS = {
	{ ANDROID, AARCH64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "NATIVE_I128", "NATIVE_F16", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "ANDROID", "AARCH64" } },
	{ ANDROID, X86_64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "ANDROID", "X86_64" } },
	{ NONE, AARCH64, { "NO_LIBC", "FREESTANDING", "FREESTANDING_ELF", "BACKTRACE", "PRINT_PANIC", "NATIVE_I128", "NATIVE_F16", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "AARCH64" } },
	{ NONE, RISCV32, { "NO_LIBC", "FREESTANDING", "FREESTANDING_ELF", "BACKTRACE", "PRINT_PANIC", "NATIVE_F128", "ARCH_32_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "RISCV32" } },
	{ NONE, RISCV64, { "NO_LIBC", "FREESTANDING", "FREESTANDING_ELF", "BACKTRACE", "PRINT_PANIC", "NATIVE_I128", "NATIVE_F128", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "RISCV64" } },
	{ NONE, X86, { "NO_LIBC", "FREESTANDING", "FREESTANDING_ELF", "BACKTRACE", "PRINT_PANIC", "ARCH_32_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "X86" } },
	{ NONE, X86_64, { "NO_LIBC", "FREESTANDING", "FREESTANDING_ELF", "BACKTRACE", "PRINT_PANIC", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "X86_64" } },
	{ FREEBSD, X86, { "LIBC", "BACKTRACE", "PRINT_PANIC", "ARCH_32_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "BSD", "FREEBSD", "X86" } },
	{ FREEBSD, X86_64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "BSD", "FREEBSD", "X86_64" } },
	{ IOS, AARCH64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "NATIVE_I128", "NATIVE_F16", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "DARWIN", "IOS", "AARCH64" } },
	{ IOS, X86_64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "DARWIN", "IOS", "X86_64" } },
	{ LINUX, AARCH64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "NATIVE_I128", "NATIVE_F16", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "LINUX", "AARCH64" } },
	{ LINUX, RISCV32, { "LIBC", "BACKTRACE", "PRINT_PANIC", "NATIVE_F128", "ARCH_32_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "LINUX", "RISCV32" } },
	{ LINUX, RISCV64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "NATIVE_I128", "NATIVE_F128", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "LINUX", "RISCV64" } },
	{ LINUX, X86, { "LIBC", "BACKTRACE", "PRINT_PANIC", "ARCH_32_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "LINUX", "X86" } },
	{ LINUX, X86_64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "LINUX", "X86_64" } },
	{ MACOS, AARCH64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "NATIVE_I128", "NATIVE_F16", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "DARWIN", "MACOS", "AARCH64" } },
	{ MACOS, X86_64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "DARWIN", "MACOS", "X86_64" } },
	{ WIN32, X86_64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "WIN32", "X86_64" } },
	{ NETBSD, AARCH64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "NATIVE_I128", "NATIVE_F16", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "BSD", "NETBSD", "AARCH64" } },
	{ NETBSD, X86, { "LIBC", "BACKTRACE", "PRINT_PANIC", "ARCH_32_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "BSD", "NETBSD", "X86" } },
	{ NETBSD, X86_64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "BSD", "NETBSD", "X86_64" } },
	{ OPENBSD, X86, { "LIBC", "BACKTRACE", "PRINT_PANIC", "ARCH_32_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "BSD", "OPENBSD", "X86" } },
	{ OPENBSD, X86_64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "BSD", "OPENBSD", "X86_64" } },
	{ UNKNOWN, WASM32, { "NO_LIBC", "FREESTANDING", "FREESTANDING_WASM", "BACKTRACE", "PRINT_PANIC", "NATIVE_I128", "ARCH_32_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "WASM", "WASM32" } },
	{ UNKNOWN, WASM64, { "NO_LIBC", "FREESTANDING", "FREESTANDING_WASM", "BACKTRACE", "PRINT_PANIC", "NATIVE_I128", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "WASM", "WASM64" } },
	{ EMSCRIPTEN, WASM32, { "LIBC", "BACKTRACE", "PRINT_PANIC", "NATIVE_I128", "ARCH_32_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "POSIX", "EMSCRIPTEN", "WASM", "WASM32" } },
	{ WIN32, AARCH64, { "LIBC", "BACKTRACE", "PRINT_PANIC", "NATIVE_I128", "NATIVE_F16", "ARCH_64_BIT", "LITTLE_ENDIAN", "SAFE_MODE", "DEBUG_SYMBOLS", "WIN32", "AARCH64" } },
};

<*
 Features c3c enables for a default build for `target`; none for a target c3c lacks.
*>
fn String[] features(Allocator allocator, Target target)
{
	foreach (t : C3C_TARGETS)
	{
		if (t.os == target.os && t.arch == target.arch) return alloc::clone_slice(allocator, t.features);
	}
	return {};
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
