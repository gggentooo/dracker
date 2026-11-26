# Dracker — Working Rules for Qwen and Inkling

This file is for the local models **Qwen** and **Inkling**. It adds to [`agents.md`](./agents.md); it does not replace it. All five rules in `agents.md` still apply. Where this file is stricter, this file wins.

Read the whole file before you start a task. Read it again before you change the task list or write in `docs/changelog.md`.

---

## 1. Why this file exists

On 2026-11-26 a task (T73) was closed as done when it was not:

- The test suite failed on its first assertion. The changelog still said "all unit tests run successfully". The tests had never been run.
- The code had two real bugs. One was a check that treated "not found" as "found", because the helper returned `text.length` for "not found" and the code tested it as a boolean. The other was a number read with a counter that started at 1 instead of 0.
- Four expected values in the tests were wrong. They had been guessed, not calculated.
- The work was signed "Claude (agent)" instead of the model's real name.
- Edits to `docs/todo.md` removed the `---` separators between stages, dropped an example script, and left the file without a final newline.

Every rule below prevents one of these mistakes. Follow them literally, even when a rule seems obvious.

---

## 2. Hard gates

A gate is a check that must pass before you continue. **If a gate fails, stop at that point.** Do not move the task to *Done*. Do not write a changelog entry that says the work is finished. Fix the problem, or report it to the owner with the real output.

### Gate 1 — The test suite really passes

1. Run this command from the `dracker/` folder:

   ```zsh
   dub test --compiler=ldc2 --config=headless 2>&1 | tail -5
   ```

   It takes about 3 minutes. Wait for it to finish. Do not guess the result.
2. The output must contain the line `N modules passed unittests` (N is the number of test modules, 38 or more on 2026-11-26). It must not contain `FAILED`, `AssertError`, `Error:` or `Segmentation fault`.
3. If the task touched anything in `source/platform/`, `source/app/studio_app.d`, `source/app/gui_shell.d` or `source/app/audio_host.d`, also run `dub test --compiler=ldc2 --config=app 2>&1 | tail -5`. It must say `4 modules passed unittests` (or more).
4. Copy the last output line **exactly as printed** into the changelog entry (see section 6).

D stops a test module at the **first** failed assertion. After you fix one failure, run the suite again, because the next assertion in the same module may fail too. Repeat until the suite passes.

### Gate 2 — Zero compiler warnings

Run this from `dracker/` and list every file you created or changed at the end:

```zsh
V=$(dub describe --compiler=ldc2 --config=headless --data=versions --data-list | sed 's/^/-d-version=/' | tr '\n' ' ')
I=$(dub describe --compiler=ldc2 --config=headless --data=import-paths --data-list | sed 's/^/-I/' | tr '\n' ' ')
eval ldc2 -w -unittest -c -o- $I -Itests $V source/path/one.d tests/unit/one_test.d
echo "exit $?"
```

The output must be empty apart from `exit 0`. Any warning counts as a failure.

### Gate 3 — No inline comments

```zsh
grep -n '//' <every file you created or changed>
```

This must print nothing, except for `//` inside a string literal such as a URL. Comments are allowed only in the file header block and in the DDoc block above a function (`agents.md` Rule 1). This also applies to test files.

### Gate 4 — Every claim has evidence

Each sentence in a changelog entry, a *Done* entry or your final report that says something was checked must name a command **you ran in this session**, followed by the line it printed.

- Allowed: `dub test --compiler=ldc2 --config=headless` → `38 modules passed unittests`.
- Not allowed: "all tests pass", "verified", "works correctly", or "exit 0" with no command, or for a command you did not run.

If you did not run something, write "not run" and why.

### Gate 5 — The real time

Before you write a timestamp, run:

```zsh
date '+%Y-%m-%d %H:%M:%S KST'      # for docs/changelog.md
```

Paste what it prints. Never type a time from memory and never round it.

### Gate 6 — Your real name

Sign every entry with the exact model name the owner gave you in your prompt, for example `Qwen3.8-Flash-Next Gyro-S`. Inkling uses its own full model name the same way. **Never** sign as "Claude", "agent", "assistant", "AI" or the name of another model. If you do not know your exact name, ask the owner before you write the entry.

### Gate 7 — The task list is changed only with `tools/todo.py`

`docs/todo.json` is the task list. `docs/todo.md` is written from it by `tools/todo.py` (`agents.md` Rule 6).

- **Never edit `docs/todo.md`.** Not with an editor, not with `sed`, not with a script of your own.
- **Never edit `docs/todo.json` by hand, and never write your own script to change it.** Use the commands in section 5.
- After your last change, run:

  ```zsh
  python3 tools/todo.py check
  ```

  It must print a line that starts with `ok:`. If it prints anything else, stop and fix that first.
- Read your result once: `python3 tools/todo.py show <id>` for every task you added or changed.

### Gate 8 — The owner decides

`agents.md` Rule 5 applies.

- A **Decision** task is closed only when the owner has said so in this conversation. Record what the owner said, with the date.
- If the owner accepted the proposals, the *Done* entry repeats the proposal text. It must not lose any of it.
- If you find a new open question while working (for example "should positions count across the whole arrangement?"), do not decide it in code. Add a new **Decision** task with your proposal marked **(proposed)**, and tell the owner.

### Gate 9 — Stay inside the task

- Change only the files named in the task's **Files** line, plus the task list (through `tools/todo.py` only), `docs/changelog.md` and, if needed, `agents.md` (package map) and `docs/manual.md`.
- If you need to change any other file, stop and ask the owner first.
- Never run `git commit`, `git push`, `git reset`, `git checkout -- <file>` or `git stash`. The owner commits.
- Never edit `../architecture.md`, `docs/manual.md` or `agents.md` unless the task or the owner asks for it.

### Gate 10 — When you are stuck

If a gate still fails after two honest attempts to fix it, stop. Report:

1. which gate failed;
2. the exact command and its last 20 lines of output;
3. what you tried;
4. what you think is wrong.

The task stays open. An honest "not done" is always better than a false "done".

---

## 3. How to do a Build task, step by step

Do these steps in order. Do not skip any.

1. **Read the task** (`python3 tools/todo.py show <id>`): its **Files**, **Task** and **Needs**. Every task in **Needs** must be in *Done*. If one is not, stop and tell the owner.
2. **Read the decisions** the task depends on, which are the *Done* entries of the tasks in **Needs**. The code must follow them word for word.
3. **Read the existing code** you will use. For each function you call, read its DDoc and its body, and write down:
   - what it returns when something is **not found** or **fails**. It might be `-1`, `text.length`, `0`, `null`, `false` or an `ok` flag;
   - whether it takes `ref` or `out` parameters. An `out` parameter is **reset** when the call starts, so never pass the same variable as both the input and the `out` argument.
4. **Look for constants that already exist** before you add one. Use `grep -rn "NAME" source/`. For example, `io.project_format` already has `DEFAULT_TIME_SIG_NUMERATOR`, `MAX_LINES` and `MAX_TIME_SIG_NUMERATOR`, and `StudioSession` has `LINES_PER_WHOLE_NOTE`. Import a constant; do not declare a second copy. Name a constant for what it really is: 16 lines is a **whole note**, not a quarter note.
5. **Write the acceptance table first**, before any code. List the inputs and the expected outputs, and work out each output by hand with the arithmetic written out in your notes:

   | Input | Working | Expected |
   | --- | --- | --- |
   | position `4.4.4` in 4/4 (16 lines per bar, 4 per beat) | (4−1)·16 + (4−1)·4 + (4−1) = 48 + 12 + 3 | line 63 |
   | position `2.3.2` in 3/4 (12 lines per bar, 4 per beat) | (2−1)·12 + (3−1)·4 + (2−1) = 12 + 8 + 1 | line 21 |
   | length `1/2` in 4/4 (4 lines per beat) | 1 · 4 / 2 | 2 lines |

   Then check every row a second way. For a conversion, work back from the result to the input (line 63 → bar 63 / 16 + 1 = 4, beat (63 mod 16) / 4 + 1 = 4, sixteenth 63 mod 4 + 1 = 4). If the two ways disagree, the row is wrong. Fix it before you write code.
6. **Write the code in small functions.** For each function:
   - Compare a "not found" result against the exact value the helper returns. Write `if (index != text.length)`, never `if (index)`.
   - Start a number you build digit by digit at `0`.
   - Convert to `ulong` **before** you multiply: write `(cast(ulong) bar - 1) * linesPerBar`, never `(bar - 1) * linesPerBar` with `uint` values. Test the largest input as well (`uint.max`).
   - A suggestion in an error must be a value the same parser accepts. Test that: parse the suggestion and check that it is accepted.
   - Give every function a DDoc block (`Params:`, `Returns:`). Indent the `Returns:` text by two spaces on every line, like `Params:`.
7. **Write the tests** from the acceptance table: one `assert` per row, using the literal expected value from the table. Also add:
   - every refusal, with its offset, length, reason and suggestion;
   - the edges: empty text, 0, 1, the largest allowed value, one past it, and a number too large for the type;
   - round trips (format, then parse, gives the same value).
8. **Run Gate 2** (warnings) for quick feedback while you work, then **Gate 1** (the full suite). When a test fails, decide which one is wrong, the code or the expected value, by working the row by hand again. Never change an expected value just to make the test pass. Say which side was wrong in the changelog.
9. **Mutation check (for bug fixes).** For each bug you fixed, put the bug back for a moment, run the tests, and confirm that a test now fails. Then remove the bug again. If no test fails, add a test that does.
10. **Run Gates 3, 6 and 7**, then write the docs (sections 5 and 6).
11. **Write the final report** (section 7).

---

## 4. D pitfalls seen in this project

| Pitfall | What to do |
| --- | --- |
| A helper returns `text.length` (or `-1`) for "not found", and the code uses it as a boolean | Compare against the exact sentinel value. |
| A digit counter starts at 1 | Start at 0. |
| `uint` arithmetic overflows before it is stored in a `ulong` | Cast one value to `ulong` first. |
| The same variable is passed as input and as an `out` argument | `out` resets it at the start of the call; use two variables. |
| `body` is used as a variable name | `body` is a reserved word in D; choose another name. |
| A method is called `rename` or `remove` and clashes with `std.file` | Import `std.file` functions under an alias. |
| `&x` is taken of a `foreach (ref x; …)` variable in `@safe` code | Loop over an index instead. |
| Test output written to stdout is lost when an assertion aborts | Write diagnostics to stderr, or put them in the assert message. |
| A test module stops at its first failed assertion | Run the suite again after every fix, until it passes. |

---

## 5. Changing the task list (`tools/todo.py`)

All commands run from inside `dracker/`. Every command that changes something needs `--author` with your exact model name (Gate 6). The script computes the stages, gives new ids, writes the timestamp from the clock, and adds a changelog entry to the list by itself. Do none of these by hand.

1. **Find and read tasks.**

   ```zsh
   python3 tools/todo.py list --stage 0        # tasks that can start now
   python3 tools/todo.py show T76              # one task in full
   ```

2. **Finish a Build task** (only after Gates 1–6 pass):

   ```zsh
   python3 tools/todo.py done T76 --author "Qwen3.8-Flash-Next Gyro-S" \
       --text "What was built, in two or three sentences. Recorded in docs/changelog.md (2026-11-26 15:00:00 KST)."
   ```

   If the owner must still check something by hand (sound, GUI), do **not** run `done`. Leave the task open and set a status line instead:

   ```zsh
   python3 tools/todo.py set T76 --author "<your name>" --status "Built 2026-11-26; waiting for the owner to check the sound."
   ```

3. **Close a Decision task** only when the owner said so in this conversation (Gate 8). `--how` says what the owner said. `--text` holds the **whole** decision, including examples. For a long text, write it to a file first and pass `@file`:

   ```zsh
   python3 tools/todo.py show T90 > /tmp/t90.txt     # copy the proposal text from here into /tmp/t90-done.txt
   python3 tools/todo.py done T90 --author "<your name>" --how "owner accepted the proposal" --text @/tmp/t90-done.txt
   ```

   In a multi-line text, every line after the first starts with two spaces or more (a nested bullet is `  - text`). The script refuses anything else.

4. **Add a task** (for example a new open question, as a Decision with your proposal marked **(proposed)**):

   ```zsh
   python3 tools/todo.py add --author "<your name>" --area Compose --type Decision \
       --title "Short title" --files '`source/compose/x.d`' \
       --task "Decide … **(proposed)** …" --needs T74,T76
   ```

   The script prints the new id. Leave `--needs` out when the task needs nothing.

5. **Change a task:** `set <id>` with `--title`, `--area`, `--type`, `--files`, `--task`, `--append-task` (adds one nested bullet), `--status` or `--needs`.

6. **Reopen a finished task:** `python3 tools/todo.py reopen T73 --author "<your name>" --reason "Why it is not done."`

7. **Change a feature section** (the facts and decisions above the tasks): `feature list`, `feature show F4`, then `feature set F4 --author "<your name>" --append "- A new fact."` or `--replace "old text" "new text"`.

8. **Name your changelog entry** once, at the end: `python3 tools/todo.py log --author "<your name>" --title "T76 done; T93 added"`. Add `--note "…"` for anything the automatic lines do not say. You cannot change another author's entry; if an old entry is wrong, say so with `--note`.

9. **Check:** `python3 tools/todo.py check` (Gate 7).

If the script cannot do what you need, stop and tell the owner. Do not work around it.

---

## 6. Writing the entry in `docs/changelog.md`

The newest entry goes at the **top**, directly below the `---` under "Entry Format". Use exactly these fields, in this order:

```md
## [2026-11-26 13:01:22 KST]
- **Author:** Qwen3.8-Flash-Next Gyro-S
- **Task:** T74 (Module writer)
- **Affected Files:**
  - `source/compose/module_writer.d` (new)
  - `tests/unit/compose_module_test.d` (new)
  - `docs/todo.json`, `docs/todo.md` (through `tools/todo.py`)
- **Description:**
  - What changed and why, one bullet per file or topic.
  - Any bug found on the way, and whether the code or the test was wrong.
- **Verification:**
  - `dub test --compiler=ldc2 --config=headless` → `38 modules passed unittests`
  - `ldc2 -w … <files>` → no output, exit 0
  - `grep -n '//' <files>` → no matches
  - Not run: `--config=app` tests (the task changed no app-only files).

---
```

- **Affected Files** lists every file you created, changed or deleted. Check it against `git status --short`.
- **Verification** follows Gate 4: commands you ran, with the line each printed.

---

## 7. Final report to the owner

End every task with a short report in this form:

1. **Done:** what you built or recorded, by task id.
2. **Checks:** the Verification lines from your changelog entry.
3. **Not done / open:** anything you skipped, any gate that failed, and any new Decision task you added, with your proposal.
4. **Files changed:** the output of `git status --short`.

Do not write "everything works". Name the checks instead.

---

## 8. Checklist before you say a task is finished

Copy this list into your notes and tick each item only after doing it:

- [ ] Every task in **Needs** is in *Done*.
- [ ] An acceptance table exists, and every expected value was worked out by hand and checked a second way.
- [ ] Every "not found" check compares against the exact sentinel; digit counters start at 0; multiplications are widened before they can overflow.
- [ ] No constant duplicates an existing one, and every name says what the value is.
- [ ] Gate 1: the full headless suite was run in this session and printed `N modules passed unittests`.
- [ ] Gate 2: `ldc2 -w` printed nothing for every changed file.
- [ ] Gate 3: `grep -n '//'` printed nothing.
- [ ] Mutation check done for every bug fix.
- [ ] Gate 5: the timestamps come from `date`.
- [ ] Gate 6: the entries are signed with my exact model name.
- [ ] Gate 7: the task list was changed only with `tools/todo.py`, and `python3 tools/todo.py check` prints `ok:`.
- [ ] Gate 8: no decision was made without the owner; new questions became Decision tasks.
- [ ] Gate 9: only the allowed files changed; no git commands that change history or the working tree.
- [ ] The final report is written (section 7).
