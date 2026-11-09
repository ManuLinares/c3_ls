module lsp::bindgen;

import std;

faultdef MSVC_CRT_NOT_FOUND, WINDOWS_SDK_NOT_FOUND, UNSUPPORTED_KERNEL_ARCH;

struct WindowsKit
{
	String root;
	bool is_kernel; // A km/ header: km/, km/crt/ and shared/ replace um/, shared/, ucrt/ and the MSVC CRT.
}

<*
 The fix to print for a Windows SDK lookup fault, or empty for other faults.
*>
fn String windows_sdk_hint(fault err)
{
	switch (err)
	{
		case MSVC_CRT_NOT_FOUND: return "Windows CRT headers (vcruntime.h) not found. Run: c3c fetch-sdk windows --fetch-headers";
		case WINDOWS_SDK_NOT_FOUND: return "Windows SDK headers (windows.h) not found. Run: c3c fetch-sdk windows --fetch-headers";
		default: return "";
	}
}

<*
 Directories that may hold c3c's MSVC SDK, in the order c3c searches them.
*>
fn String[] msvc_sdk_roots()
{
	List{String} roots;
	roots.tinit();
	if (try exe_dir = path::tnew(env::executable_path() ?? "").parent().tappend("msvc_sdk")) roots.push((String)exe_dir);
	if (try sdk = env::tget_var("C3_MSVC_SDK")) roots.push(sdk);
	$if env::WIN32:
		if (try app_data = path::tnew(env::tget_var("LOCALAPPDATA")).tappend("c3", "msvc_sdk")) roots.push((String)app_data);
	$else
		if (try cache_home = path::tnew(env::tget_var("XDG_CACHE_HOME")).tappend("c3", "msvc_sdk")) roots.push((String)cache_home);
		if (try home = path::tnew(env::tget_var("HOME")).tappend(".cache", "c3", "msvc_sdk")) roots.push((String)home);
	$endif
	return roots.array_view();
}

<*
 The MSVC CRT include directory, holding vcruntime.h, of the first SDK root that has one.
*>
fn String? find_msvc_crt_dir(String[] sdk_roots)
{
	foreach (root : sdk_roots)
	{
		Path? crt = path::tnew(root).tappend("include", "crt");
		if (catch crt) continue;
		if (file::is_file((String)crt.tappend("vcruntime.h") ?? "")) return (String)crt;
	}
	return MSVC_CRT_NOT_FOUND~;
}

<*
 The Windows Kits include directory that contains the header or one of the include directories.
*>
fn WindowsKit? find_windows_kit(BindgenOptions options)
{
	if (try kit = find_windows_kit_at(options.header_path)) return kit;
	foreach (dir : options.include_dirs)
	{
		if (try kit = find_windows_kit_at(dir)) return kit;
	}
	return NOT_FOUND~;
}

<*
 The Windows Kits layout inside c3c's MSVC SDK for the target's architecture, for headers that
 include windows.h from outside a kit.
*>
fn WindowsKit? find_msvc_sdk_windows_kit(String target_triple)
{
	String arch = (target_triple.len > 0 ? target_triple : host_windows_triple()).starts_with("aarch64") ? "arm64" : "x64";
	foreach (root : msvc_sdk_roots())
	{
		Path? kit = path::tnew(root).tappend("include", arch);
		if (catch kit) continue;
		if (is_kit_dir(kit, "um") && is_kit_dir(kit, "shared") && is_kit_dir(kit, "ucrt")) return { .root = (String)kit };
	}
	return WINDOWS_SDK_NOT_FOUND~;
}

<*
 The kit, a directory holding shared/ and um/ or km/, that contains `path`.
*>
fn WindowsKit? find_windows_kit_at(String path) @local
{
	Path dir = path.to_absolute_path(tmem)!;
	if (file::is_file((String)dir)) dir = dir.parent()!;
	String entered_from;
	while (true)
	{
		if (is_kit_dir(dir, "shared") && (is_kit_dir(dir, "um") || is_kit_dir(dir, "km"))) return { (String)dir, entered_from == "km" };
		entered_from = dir.basename();
		dir = dir.parent()!;
	}
}

fn bool is_kit_dir(Path kit_root, String name) @local
{
	return file::is_dir((String)kit_root.tappend(name) ?? "");
}

<*
 Points clang at a Windows Kits header set with the MSVC target. User-mode headers get the kit's um,
 shared and ucrt directories and the MSVC CRT from c3c's SDK, which the kits do not ship. Kernel
 headers get km, km/crt and shared, with _KERNEL_MODE and the architecture define a driver build
 passes. On case-sensitive hosts the kit is read through a case-insensitive overlay, set as
 `vfs_overlay`, since its includes do not match file name case.
*>
fn void? configure_windows_kit(BindgenOptions* options, WindowsKit kit)
{
	Path root = path::tnew(kit.root)!;
	if (options.target.len == 0) options.target = host_windows_triple();
	options.has_windows_kit = true;
	String[3] kit_dirs;
	if (kit.is_kernel)
	{
		kit_dirs = { (String)root.tappend("km")!, (String)root.tappend("km", "crt")!, (String)root.tappend("shared")! };
		add_unique_define(options, "_KERNEL_MODE");
		add_unique_define(options, kernel_arch_define(options.target)!);
	}
	else
	{
		kit_dirs = { (String)root.tappend("um")!, (String)root.tappend("shared")!, (String)root.tappend("ucrt")! };
	}
	foreach (dir : kit_dirs) add_unique_include(options, dir);
	if (!kit.is_kernel) add_unique_include(options, find_msvc_crt_dir(msvc_sdk_roots())!);

	$if !env::WIN32:
		Path overlay = unique_temp_path("c3_bindgen_kit", ".yaml")!;
		file::save(overlay, case_insensitive_overlay(&kit_dirs))!;
		options.vfs_overlay = (String)overlay;
	$endif
}

<*
 Whether a missing windows.h should be taken from c3c's MSVC SDK: no kit is set up yet and the
 target is unset or an MSVC one.
*>
fn bool should_use_msvc_sdk_for(BindgenOptions options, String missing_header)
{
	if (options.has_windows_kit || missing_header.to_lower_tcopy() != "windows.h") return false;
	return options.target.len == 0 || options.target.ends_with("windows-msvc");
}

<*
 The architecture macro that the WDK build defines for kernel headers, which select their
 architecture-specific declarations with it instead of the compiler's _M_* macros.
*>
fn String? kernel_arch_define(String target_triple) @local
{
	switch
	{
		case target_triple.starts_with("x86_64"): return "_AMD64_";
		case target_triple.starts_with("aarch64") || target_triple.starts_with("arm64"): return "_ARM64_";
		case target_triple.starts_with("i386") || target_triple.starts_with("i686"): return "_X86_";
		default: return UNSUPPORTED_KERNEL_ARCH~;
	}
}

<*
 Clang VFS overlay listing every file under `dirs`, matched without regard to case.
*>
fn String case_insensitive_overlay(String[] dirs) @local
{
	DString out;
	out.tinit();
	out.append(`{"version":0,"case-sensitive":"false","roots":[`);
	foreach (i, dir : dirs)
	{
		if (i > 0) out.append(",");
		out.append(`{"type":"directory","name":`);
		append_json_string(&out, dir);
		out.append(`,"contents":[`);
		append_overlay_entries(&out, dir);
		out.append("]}");
	}
	out.append("]}");
	return out.str_view();
}

fn void append_overlay_entries(DString* out, String dir) @local
{
	PathList? entries = path::ls(tmem, path::tnew(dir) ?? (Path)"", no_dirs: false, mask: "", recursive: false);
	if (catch entries) return;
	foreach (i, entry : entries)
	{
		String name = (String)entry;
		String full = (String)path::tnew(dir).tappend(name) ?? "";
		if (i > 0) out.append(",");
		out.append(`{"name":`);
		append_json_string(out, name);
		if (file::is_dir(full))
		{
			out.append(`,"type":"directory","contents":[`);
			append_overlay_entries(out, full);
			out.append("]}");
			continue;
		}
		out.append(`,"type":"file","external-contents":`);
		append_json_string(out, full);
		out.append("}");
	}
}

fn void append_json_string(DString* out, String s) @local
{
	out.append_char('"');
	foreach (c : s)
	{
		if (c == '"' || c == '\\') out.append_char('\\');
		out.append_char(c);
	}
	out.append_char('"');
}
