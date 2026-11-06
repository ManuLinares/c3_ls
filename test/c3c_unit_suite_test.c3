module lsp::c3c_unit_suite_test;
import analyzer, std;

const String[*] CANDIDATE_DIRS = {
	"/home/mb/scripts/c3c/test/unit",
	"../c3c/test/unit",
	"../../c3c/test/unit"
};

List{String}* current_file_errors @local = null;

fn void on_unit_diagnostic(SourceFile* file, Range range, DiagnosticLevel level, String message)
{
	if (level == DiagnosticLevel.ERROR && current_file_errors)
	{
		String p = file ? file.path : "";
		String msg = string::format(mem, "%s:%d:%d: %s", p, range.start.line + 1, range.start.column + 1, message);
		current_file_errors.push(msg);
	}
}

fn void test_c3c_unit_test_suite_syntax() @test
{
	String unit_dir = env::tget_var("C3C_UNIT_TEST_DIR") ?? "";
	if (unit_dir.len == 0 || !file::is_dir(unit_dir))
	{
		foreach (cand : CANDIDATE_DIRS)
		{
			if (file::is_dir(cand))
			{
				unit_dir = cand;
				break;
			}
		}
	}

	if (unit_dir.len == 0)
	{
		io::printfn("c3c unit test directory not found; skipping c3c unit suite syntax test.");
		return;
	}

	Path? root_p = path::tnew(unit_dir);
	if (catch root_p) return;

	PathList? entries = path::ls(tmem, root_p, no_dirs: true, mask: "*.c3", recursive: true, rebase: root_p);
	if (catch entries) return;

	sz total_files = 0;
	sz passed_files = 0;
	sz failed_files = 0;

	diagnostics::callback = &on_unit_diagnostic;
	defer diagnostics::callback = null;

	foreach (entry : entries)
	{
		String file_path = (String)entry;
		total_files++;

		bool ok = false;
		List{String} errors;
		errors.init(mem);
		defer
		{
			foreach (e : errors) e.free(mem);
			errors.free();
		};

		@pool()
		{
			String? content = (String)file::load(tmem, file_path);
			if (try text = content)
			{
				current_file_errors = &errors;
				AnalyzerContext* ctx = context::create(tmem);
				defer context::free(ctx);

				ok = context::parse_and_register(ctx, text, file_path);
				current_file_errors = null;
			}
		};

		if (ok && errors.len() == 0)
		{
			passed_files++;
		}
		else
		{
			failed_files++;
			io::eprintfn("--- FAILED: %s ---", file_path);
			foreach (err_msg : errors)
			{
				io::eprintfn("  %s", err_msg);
			}
		}
	}

	io::printfn("c3c unit suite syntax: %d scanned, %d passed, %d failed", (int)total_files, (int)passed_files, (int)failed_files);
	test::eq(failed_files, 0);
}