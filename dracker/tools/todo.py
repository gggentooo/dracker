#!/usr/bin/env python3
"""Maintains the Dracker task list.

docs/todo.json is the source of truth. docs/todo.md (the list) and
docs/todo-guides.md (the step-by-step guides of the open tasks) are generated
from it by this script and must never be edited by hand (agents.md Rule 6). Every command
that changes the list validates it, writes docs/todo.json, regenerates
docs/todo.md and records the change in the list's own changelog with the time
read from the clock.

Run `python3 tools/todo.py help` for the commands. Python 3.8+, standard
library only.
"""

import argparse
import datetime
import json
import os
import re
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSON_PATH = os.path.join(ROOT, "docs", "todo.json")
MD_PATH = os.path.join(ROOT, "docs", "todo.md")
GUIDES_PATH = os.path.join(ROOT, "docs", "todo-guides.md")
KST = datetime.timezone(datetime.timedelta(hours=9))
TASK_TYPES = ("Build", "Decision")
ID_PATTERN = re.compile(r"^T[0-9]{2,}$")
FEATURE_ID_PATTERN = re.compile(r"^F[0-9]+$")
CHANGE_KINDS = ("Added", "Modified", "Removed", "Note")
SESSION_MINUTES = 60
NO_NEEDS = "—"

GUIDE = """# Dracker Tasks

> **Generated file. Do not edit it.** `tools/todo.py` writes this file from `docs/todo.json`. To change anything here, run the script (`python3 tools/todo.py help`); see `agents.md` Rule 6. A hand edit is lost at the next run and makes `python3 tools/todo.py check` fail.

## How this list works

1. **One source.** `docs/todo.json` holds the features, the tasks and the changelog below. Humans and agents change it only through `tools/todo.py`.
2. **Tasks.** Each task has an area tag, a title, an id and a type: `#### [Area] Title · T00 · Decision|Build`. Below it: **Files** (all relevant source files), **Task** (brief description), and **Needs** (ids of tasks that must be finished first, or `—`).
   - **Area tags** name the project part, following the package map in `agents.md`: e.g. `[App]`, `[GUI/widgets]`, `[GUI/views]`, `[IO]`, `[Sequencer]`, `[Platform]`, `[Tests]`, `[Docs]`, `[Project]`; for the composition helper `[Compose]` (core library), `[Compose/script]` (command interpreter), `[Compose/program]` (command line), `[Build]`.
   - **Decision** tasks are made by the owner (`agents.md` Rule 5). Agents may suggest a default marked **(proposed)** but must not decide.
   - **Build** tasks are implementation work. They follow `agents.md` (comment policy, unit tests for every component, zero warnings, `docs/changelog.md` entry).
3. **Stages are computed.** *Stage 0* tasks can start now. A task's stage is one higher than the highest stage among its open *Needs*. The script works this out; nobody moves tasks between stages.
4. **Stable ids.** Ids are never reused or renumbered. The script gives a new task the next free id.
5. **Done.** A finished task moves to *Done* with its completion date and where its outcome is recorded (decisions go in `docs/manual.md` or `../architecture.md`). The newest is listed first.
6. **New open questions** found during work become tasks here.
7. **Concise language.** Write in brief, clear English.
8. **Changelog.** The script adds an entry for every change, with the time from the clock and the author it was given. It covers this list only; code changes are logged in `docs/changelog.md` (`agents.md` Rule 4).
9. **Guides.** A task may carry a guide: detailed instructions on what to write and how, for whoever builds it. The guides of the open tasks are in `docs/todo-guides.md` (also generated). `python3 tools/todo.py brief T00` prints everything needed to build one task: the task, the decisions it rests on, its guide and the finishing steps.
"""

GUIDES_HEADER = """# Dracker Task Guides

> **Generated file. Do not edit it.** `tools/todo.py` writes this file from `docs/todo.json` (`agents.md` Rule 6). Change a guide with `python3 tools/todo.py guide T00 --author "<name>" --text @file`.

A guide says what to write for one task and how: what to read first, the existing code to call (with exact signatures), the new code, the order of the steps, an acceptance table with worked values, and the tests. It was written by reading the code as it was on the date shown; if the code no longer matches the guide, stop and tell the owner instead of guessing. To get one task with everything it rests on, run `python3 tools/todo.py brief T00`.

Only open tasks are listed, in stage order. A task without a guide is named at the end.
"""

BRIEF_FINISH = """## Before you say it is finished

Follow `qwen-inkling.md` (hard gates) and `agents.md` Rules 1 to 6. In short:

1. `dub test --compiler=ldc2 --config=headless 2>&1 | tail -5` must print `N modules passed unittests`.
2. Zero warnings under `ldc2 -w` and no `//` comments in the files you changed (Gates 2 and 3).
3. Write the entry in `docs/changelog.md` with the time from `date` and your exact model name.
4. Close the task (only when every gate passed; leave it open and set `--status` if the owner must check something):

       python3 tools/todo.py done {id} --author "<your exact model name>" --text "What was built. Recorded in docs/changelog.md (<timestamp> KST)."
       python3 tools/todo.py check

If anything in this brief does not match the code you find, stop and tell the owner. Do not guess.
"""


class TodoError(Exception):
    """A problem the user of the script can fix."""


def now():
    return datetime.datetime.now(KST).replace(microsecond=0)


def read_text_argument(value):
    """Returns an argument's text: '@path' reads a file, '-' reads stdin."""
    if value is None:
        return None
    if value == "-":
        return sys.stdin.read().rstrip("\n")
    if value.startswith("@"):
        with open(value[1:], encoding="utf-8") as handle:
            return handle.read().rstrip("\n")
    return value


def load():
    if not os.path.exists(JSON_PATH):
        raise TodoError("docs/todo.json does not exist")
    with open(JSON_PATH, encoding="utf-8") as handle:
        return json.load(handle)


def write_atomic(path, text):
    folder = os.path.dirname(path)
    handle, temporary = tempfile.mkstemp(dir=folder, prefix=".todo-", text=True)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            out.write(text)
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.remove(temporary)
        raise


def save(data):
    validate(data)
    write_atomic(JSON_PATH, json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    write_atomic(MD_PATH, render(data))
    write_atomic(GUIDES_PATH, render_guides(data))


def task_by_id(data, task_id):
    for task in data["tasks"]:
        if task["id"] == task_id:
            return task
    raise TodoError("there is no task %s" % task_id)


def feature_by_id(data, feature_id):
    for feature in data["features"]:
        if feature["id"] == feature_id:
            return feature
    raise TodoError("there is no feature %s (see `feature list`)" % feature_id)


def stages(data):
    """Maps the id of every open task to its stage."""
    by_id = {task["id"]: task for task in data["tasks"]}
    result = {}
    visiting = set()

    def stage_of(task_id):
        if task_id in result:
            return result[task_id]
        if task_id in visiting:
            raise TodoError("the Needs of %s form a loop" % task_id)
        visiting.add(task_id)
        open_needs = [n for n in by_id[task_id]["needs"] if by_id[n]["state"] == "open"]
        value = 1 + max(stage_of(n) for n in open_needs) if open_needs else 0
        visiting.discard(task_id)
        result[task_id] = value
        return value

    for task in data["tasks"]:
        if task["state"] == "open":
            stage_of(task["id"])
    return result


def check_inline(label, text):
    if text is None or text == "" or "\n" in text:
        raise TodoError("%s must be one line of text" % label)


def check_block(label, text):
    """A multi-line field must stay inside its bullet: later lines are blank or indented."""
    lines = text.split("\n")
    if lines[0].strip() == "":
        raise TodoError("%s must start with text" % label)
    for line in lines[1:]:
        if line.strip() != "" and not line.startswith("  "):
            raise TodoError("%s: every line after the first must be indented by two spaces or more "
                            "(a nested bullet is written '  - text'); found: %r" % (label, line[:60]))
    if text != text.rstrip():
        raise TodoError("%s must not end with blank space" % label)


def check_guide(label, text):
    """A guide is free Markdown, but it must not break the page it is rendered into."""
    if text.strip() == "" or text != text.strip("\n"):
        raise TodoError("the guide of %s must hold text and not start or end with blank lines" % label)
    fenced = False
    for line in text.split("\n"):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if not fenced and (line.startswith("#") or line.strip() == "---"):
            raise TodoError("the guide of %s must not contain headings ('#') or '---' lines outside code "
                            "blocks; use bold labels such as **Steps**; found: %r" % (label, line[:60]))
    if fenced:
        raise TodoError("the guide of %s has a code block that is not closed" % label)


def validate(data):
    for key in ("features", "tasks", "changelog"):
        if not isinstance(data.get(key), list):
            raise TodoError("docs/todo.json has no list '%s'" % key)
    seen = set()
    for feature in data["features"]:
        if not FEATURE_ID_PATTERN.match(feature.get("id", "")) or feature["id"] in seen:
            raise TodoError("feature id %r is malformed or used twice" % feature.get("id"))
        seen.add(feature["id"])
        check_inline("the title of %s" % feature["id"], feature.get("title"))
        for line in feature.get("body", "").split("\n"):
            if line.startswith("#") or line.strip() == "---":
                raise TodoError("the body of %s must not contain headings or '---' lines" % feature["id"])
    ids = set()
    for task in data["tasks"]:
        task_id = task.get("id", "")
        if not ID_PATTERN.match(task_id) or task_id in ids:
            raise TodoError("task id %r is malformed or used twice" % task_id)
        ids.add(task_id)
    closed_numbers = set()
    for task in data["tasks"]:
        label = task["id"]
        check_inline("the area of %s" % label, task.get("area"))
        check_inline("the title of %s" % label, task.get("title"))
        if "]" in task["area"] or "·" in task["title"]:
            raise TodoError("%s: an area has no ']' and a title has no '·'" % label)
        if task.get("type") not in TASK_TYPES:
            raise TodoError("%s: the type is Build or Decision" % label)
        if task.get("state") not in ("open", "done"):
            raise TodoError("%s: the state is open or done" % label)
        check_block("the files of %s" % label, task.get("files") or "")
        for field in ("task", "status", "done"):
            if task.get(field) is not None:
                check_block("the %s text of %s" % (field, label), task[field])
        if task.get("guide") is not None:
            check_guide(label, task["guide"])
        if task["state"] == "open" and task.get("task") is None:
            raise TodoError("%s is open and needs a task text" % label)
        if task["state"] == "open" and task.get("done") is not None:
            raise TodoError("%s is open and must not have a done text" % label)
        if task["state"] == "done":
            if task.get("done") is None:
                raise TodoError("%s is done and needs a done text" % label)
            if not isinstance(task.get("closed"), int) or task["closed"] in closed_numbers:
                raise TodoError("%s: 'closed' must be a number no other task has" % label)
            closed_numbers.add(task["closed"])
        for need in task.get("needs", []):
            if need not in ids:
                raise TodoError("%s needs %s, which does not exist" % (label, need))
            if need == label:
                raise TodoError("%s cannot need itself" % label)
        if len(set(task["needs"])) != len(task["needs"]):
            raise TodoError("%s lists a need twice" % label)
    stages(data)
    for entry in data["changelog"]:
        for key in ("time", "author", "title"):
            check_inline("a changelog %s" % key, entry.get(key))
        try:
            datetime.datetime.fromisoformat(entry["time"])
        except ValueError:
            raise TodoError("changelog time %r is not ISO 8601" % entry["time"])
        for change in entry.get("changes", []):
            check_inline("a changelog line", change)


def render_task(task, done_section):
    lines = ["#### [%s] %s · %s · %s" % (task["area"], task["title"], task["id"], task["type"]), "",
             "- **Files:** " + task["files"]]
    if task.get("task") is not None and (not done_section or task.get("show_task")):
        lines.append("- **Task:** " + task["task"])
    if task.get("status") is not None:
        lines.append("- **Status:** " + task["status"])
    if done_section:
        lines.append("- **Done:** " + task["done"])
    lines.append("- **Needs:** " + (", ".join(task["needs"]) if task["needs"] else NO_NEEDS))
    return "\n".join(lines) + "\n"


def render(data):
    parts = [GUIDE]
    for feature in data["features"]:
        parts.append("## Feature: %s\n\n%s\n" % (feature["title"], feature["body"]))
    stage_map = stages(data)
    highest = max(stage_map.values()) if stage_map else 0
    for stage in range(highest + 1):
        heading = "## Stage 0 — Ready now" if stage == 0 else "## Stage %d" % stage
        blocks = [render_task(t, False) for t in data["tasks"]
                  if t["state"] == "open" and stage_map[t["id"]] == stage]
        parts.append(heading + "\n\n" + ("\n".join(blocks) if blocks else "No open tasks.\n"))
    done = sorted((t for t in data["tasks"] if t["state"] == "done"), key=lambda t: -t["closed"])
    parts.append("## Done\n\n" + ("\n".join(render_task(t, True) for t in done) if done else "Nothing yet.\n"))
    entries = []
    for entry in data["changelog"]:
        block = "### %s — %s, %s\n" % (entry["time"], entry["author"], entry["title"])
        if entry["changes"]:
            block += "\n" + "\n".join("- " + change for change in entry["changes"]) + "\n"
        entries.append(block)
    parts.append("## Changelog\n\n" + "\n".join(entries))
    return "\n---\n\n".join(parts)


def open_tasks_in_stage_order(data):
    stage_map = stages(data)
    tasks = [t for t in data["tasks"] if t["state"] == "open"]
    return sorted(tasks, key=lambda t: stage_map[t["id"]]), stage_map


def render_guides(data):
    tasks, stage_map = open_tasks_in_stage_order(data)
    parts = [GUIDES_HEADER]
    missing = []
    for task in tasks:
        if task.get("guide") is None:
            missing.append("%s (Stage %d)" % (task["id"], stage_map[task["id"]]))
            continue
        parts.append("## %s \u00b7 [%s] %s\n\nStage %d \u00b7 %s \u00b7 guide written %s by %s\n\n%s\n" % (
            task["id"], task["area"], task["title"], stage_map[task["id"]], task["type"],
            task.get("guide_date", "?"), task.get("guide_author", "?"), task["guide"]))
    parts.append("## Open tasks without a guide\n\n%s\n" % (
        ", ".join(missing) + ".\n\nA guide is written when the tasks it needs are built, so that it can name "
        "real functions." if missing else "None."))
    return "\n---\n\n".join(parts)


def mentioned_ids(data, text):
    known = {task["id"] for task in data["tasks"]}
    found = []
    for match in re.finditer(r"T[0-9]{2,}", text or ""):
        if match.group(0) in known and match.group(0) not in found:
            found.append(match.group(0))
    return found


def render_brief(data, task):
    stage_map = stages(data)
    lines = ["# Brief for %s: [%s] %s" % (task["id"], task["area"], task["title"]), ""]
    if task["state"] == "done":
        lines += ["This task is already done. Nothing is to be built.", ""]
    else:
        open_needs = [n for n in task["needs"] if task_by_id(data, n)["state"] == "open"]
        if open_needs:
            lines += ["**Do not start yet.** It still needs %s (it is in Stage %d). Tell the owner."
                      % (", ".join(open_needs), stage_map[task["id"]]), ""]
    lines += ["## The task", "", render_task(task, task["state"] == "done")]
    related = list(task["needs"])
    for other in mentioned_ids(data, (task.get("task") or "") + "\n" + (task.get("guide") or "")):
        if other != task["id"] and other not in related:
            related.append(other)
    finished = [task_by_id(data, n) for n in related if task_by_id(data, n)["state"] == "done"]
    if finished:
        lines += ["## What it rests on", "",
                  "These tasks are finished. Their decisions and results are binding; follow them word for word.", ""]
        for other in finished:
            lines += ["- **%s \u00b7 [%s] %s (%s).** %s" % (other["id"], other["area"], other["title"], other["type"],
                                                             other["done"]), ""]
    lines += ["## Guide", ""]
    if task.get("guide") is None:
        lines += ["No guide has been written for this task yet. If you were told to work from a guide, stop and "
                  "tell the owner; do not invent one.", ""]
    else:
        lines += ["Written %s by %s." % (task.get("guide_date", "?"), task.get("guide_author", "?")), "",
                  task["guide"], ""]
    if task["state"] == "open":
        lines += [BRIEF_FINISH.replace("{id}", task["id"])]
    return "\n".join(lines)


def record(data, author, changes, title=None):
    """Adds lines to the author's current changelog entry, or starts a new entry."""
    check_inline("the author", author)
    if author.strip().lower() in ("claude", "agent", "ai", "assistant", "claude (agent)", "model"):
        raise TodoError("--author must be the full name of the model or person, such as "
                        "'Claude Fable 5.2' or 'GLM-5.4', not %r" % author)
    moment = now()
    entry = data["changelog"][-1] if data["changelog"] else None
    current = False
    if entry is not None and entry["author"] == author:
        age = moment - datetime.datetime.fromisoformat(entry["time"])
        current = datetime.timedelta(0) <= age <= datetime.timedelta(minutes=SESSION_MINUTES)
    if not current:
        first = changes[0] if changes else "changes"
        entry = {"time": moment.isoformat(), "author": author,
                 "title": title or shorten(first.split(": ", 1)[-1]), "changes": []}
        data["changelog"].append(entry)
    elif title:
        entry["title"] = title
    entry["changes"].extend(changes)


def shorten(text, limit=70):
    text = text.rstrip(".")
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…"


def stage_changes(before, after, skip):
    moved = ["%s Stage %d → %d" % (task_id, before[task_id], after[task_id])
             for task_id in after if task_id in before and task_id not in skip
             and before[task_id] != after[task_id]]
    return ["Modified: Stages recomputed: " + "; ".join(moved) + "."] if moved else []


def parse_needs(text):
    if text is None:
        return None
    text = text.strip()
    if text in ("", NO_NEEDS, "-", "none"):
        return []
    return [part.strip() for part in text.split(",") if part.strip()]


def heading_of(task):
    return "[%s] %s" % (task["area"], task["title"])


def command_list(data, args):
    stage_map = stages(data)
    rows = []
    for task in data["tasks"]:
        if args.open and task["state"] != "open":
            continue
        if args.done and task["state"] != "done":
            continue
        if args.stage is not None and stage_map.get(task["id"]) != args.stage:
            continue
        if args.area and task["area"].lower() != args.area.lower():
            continue
        if args.no_guide and (task["state"] != "open" or task.get("guide") is not None):
            continue
        place = "stage %d" % stage_map[task["id"]] if task["state"] == "open" else "done"
        needs = ", ".join(task["needs"]) if task["needs"] else NO_NEEDS
        mark = "guide" if task.get("guide") is not None else "-"
        rows.append("%-5s %-8s %-9s %-6s %s  (needs %s)" % (task["id"], place, task["type"], mark,
                                                             heading_of(task), needs))
    print("\n".join(rows) if rows else "no tasks match")


def command_show(data, args):
    stage_map = stages(data)
    for task_id in args.ids:
        task = task_by_id(data, task_id)
        place = "Done" if task["state"] == "done" else "Stage %d" % stage_map[task_id]
        print("(%s)" % place)
        print(render_task(task, task["state"] == "done"))
        if task["state"] == "done" and task.get("task") is not None and not task.get("show_task"):
            print("(task text kept for a reopen) " + task["task"] + "\n")


def command_guide(data, args):
    task = task_by_id(data, args.id)
    if args.clear:
        if not args.author:
            raise TodoError("--author is needed")
        if task.get("guide") is None:
            raise TodoError("%s has no guide" % task["id"])
        for key in ("guide", "guide_author", "guide_date"):
            task.pop(key, None)
        record(data, args.author, ["Removed: The guide of %s." % task["id"]])
        save(data)
        print("removed the guide of %s" % task["id"])
        return
    if args.text is None:
        if task.get("guide") is None:
            raise TodoError("%s has no guide" % task["id"])
        print(task["guide"])
        return
    if not args.author:
        raise TodoError("--author is needed")
    existed = task.get("guide") is not None
    task["guide"] = read_text_argument(args.text).strip("\n")
    task["guide_author"] = args.author
    task["guide_date"] = now().date().isoformat()
    record(data, args.author, ["%s: The guide of %s." % ("Modified" if existed else "Added", task["id"])])
    save(data)
    print("%s the guide of %s" % ("changed" if existed else "added", task["id"]))


def command_brief(data, args):
    for task_id in args.ids:
        print(render_brief(data, task_by_id(data, task_id)))


def command_next_id(data, args):
    print(next_id(data))


def next_id(data):
    highest = max((int(task["id"][1:]) for task in data["tasks"]), default=0)
    return "T%02d" % (highest + 1)


def command_add(data, args):
    before = stages(data)
    task = {"id": next_id(data), "area": args.area.strip("[]"), "title": args.title, "type": args.type,
            "state": "open", "files": read_text_argument(args.files), "task": read_text_argument(args.task),
            "status": read_text_argument(args.status), "done": None,
            "needs": parse_needs(args.needs) or []}
    data["tasks"].append(task)
    validate(data)
    after = stages(data)
    record(data, args.author, ["Added: %s (%s, %s) in Stage %d." % (task["id"], heading_of(task), task["type"],
                                                                 after[task["id"]])]
           + stage_changes(before, after, {task["id"]}))
    save(data)
    print("added %s in Stage %d" % (task["id"], after[task["id"]]))


def command_set(data, args):
    task = task_by_id(data, args.id)
    before = stages(data)
    changed = []
    for field in ("area", "title", "type"):
        value = getattr(args, field)
        if value is not None:
            task[field] = value.strip("[]") if field == "area" else value
            changed.append(field)
    for field, option in (("files", args.files), ("task", args.task), ("status", args.status),
                          ("done", args.done_text)):
        value = read_text_argument(option)
        if value is not None:
            task[field] = None if value == "" and field != "files" else value
            changed.append("done text" if field == "done" else field)
    if args.append_task is not None:
        if task.get("task") is None:
            raise TodoError("%s has no task text to append to" % task["id"])
        task["task"] += "\n  - " + read_text_argument(args.append_task)
        changed.append("task (a line added)")
    needs = parse_needs(args.needs)
    if needs is not None:
        task["needs"] = needs
        changed.append("needs")
    if not changed:
        raise TodoError("nothing to change; give at least one field option")
    validate(data)
    after = stages(data)
    lines = ["Modified: %s %s changed." % (task["id"], ", ".join(changed))]
    if task["state"] == "open" and before[task["id"]] != after[task["id"]]:
        lines.append("Modified: %s moved from Stage %d to Stage %d." % (task["id"], before[task["id"]],
                                                                      after[task["id"]]))
    record(data, args.author, lines + stage_changes(before, after, {task["id"]}))
    save(data)
    print("changed %s: %s" % (task["id"], ", ".join(changed)))


def command_done(data, args):
    task = task_by_id(data, args.id)
    if task["state"] == "done":
        raise TodoError("%s is already done" % task["id"])
    open_needs = [n for n in task["needs"] if task_by_id(data, n)["state"] == "open"]
    if open_needs and not args.force:
        raise TodoError("%s still needs %s; finish those first, or pass --force with a reason in --text"
                        % (task["id"], ", ".join(open_needs)))
    if task["type"] == "Decision" and not args.how:
        raise TodoError("%s is a Decision: only the owner decides (agents.md Rule 5). Pass --how with what "
                        "the owner said, for example --how 'owner accepted the proposal'" % task["id"])
    text = read_text_argument(args.text)
    date = args.date or now().date().isoformat()
    datetime.date.fromisoformat(date)
    before = stages(data)
    task["done"] = "%s%s. %s" % (date, " (%s)" % args.how if args.how else "", text)
    task["state"] = "done"
    task["status"] = None
    task["closed"] = max((t["closed"] for t in data["tasks"] if t.get("closed") is not None), default=0) + 1
    validate(data)
    after = stages(data)
    record(data, args.author, ["Modified: %s moved to *Done*%s." % (task["id"], " (%s)" % args.how if args.how else "")]
           + stage_changes(before, after, {task["id"]}))
    save(data)
    print("%s is done" % task["id"])


def command_reopen(data, args):
    task = task_by_id(data, args.id)
    if task["state"] == "open":
        raise TodoError("%s is already open" % task["id"])
    new_text = read_text_argument(args.task)
    if new_text is not None:
        task["task"] = new_text
    if task.get("task") is None:
        raise TodoError("%s has no task text any more; pass --task with what is to be done" % task["id"])
    reason = read_text_argument(args.reason)
    check_inline("the reason", reason)
    before = stages(data)
    task["task"] += "\n  - Reopened %s: %s Before that it was closed as: %s" % (
        now().date().isoformat(), reason if reason.endswith(".") else reason + ".",
        task["done"].replace("\n", " "))
    task["state"] = "open"
    task["done"] = None
    task.pop("closed", None)
    task.pop("show_task", None)
    validate(data)
    after = stages(data)
    record(data, args.author, ["Modified: %s reopened: %s" % (task["id"], reason if reason.endswith(".") else reason + ".")]
           + stage_changes(before, after, {task["id"]}))
    save(data)
    print("%s is open again in Stage %d" % (task["id"], after[task["id"]]))


def command_feature(data, args):
    if args.action == "list":
        for feature in data["features"]:
            print("%-4s %s" % (feature["id"], feature["title"]))
        return
    if args.action == "show":
        feature = feature_by_id(data, args.id)
        print("## Feature: %s\n\n%s" % (feature["title"], feature["body"]))
        return
    if not args.author:
        raise TodoError("--author is needed")
    if args.action == "add":
        if not args.title or args.body is None:
            raise TodoError("feature add needs --title and --body")
        number = max((int(f["id"][1:]) for f in data["features"]), default=0) + 1
        feature = {"id": "F%d" % number, "title": args.title, "body": read_text_argument(args.body)}
        data["features"].append(feature)
        record(data, args.author, ["Added: Feature section \"%s\" (%s)." % (feature["title"], feature["id"])])
        save(data)
        print("added %s" % feature["id"])
        return
    feature = feature_by_id(data, args.id)
    changed = []
    if args.title is not None:
        feature["title"] = args.title
        changed.append("title")
    if args.body is not None:
        feature["body"] = read_text_argument(args.body)
        changed.append("text")
    if args.append is not None:
        feature["body"] += "\n" + read_text_argument(args.append)
        changed.append("a line added")
    if args.replace is not None:
        old, new = read_text_argument(args.replace[0]), read_text_argument(args.replace[1])
        if feature["body"].count(old) != 1:
            raise TodoError("the text to replace occurs %d times in %s; it must occur once"
                            % (feature["body"].count(old), feature["id"]))
        feature["body"] = feature["body"].replace(old, new)
        changed.append("text replaced")
    if not changed:
        raise TodoError("nothing to change; give --title, --body, --append or --replace")
    record(data, args.author, ["Modified: Feature section \"%s\" (%s): %s." % (feature["title"], feature["id"],
                                                                              ", ".join(changed))])
    save(data)
    print("changed %s: %s" % (feature["id"], ", ".join(changed)))


def command_log(data, args):
    changes = []
    for kind in CHANGE_KINDS:
        for text in getattr(args, kind.lower()) or []:
            changes.append("%s: %s" % (kind, read_text_argument(text)))
    if not changes and not args.title:
        raise TodoError("give --title or at least one of --added, --modified, --removed, --note")
    record(data, args.author, changes, args.title)
    save(data)
    print("changelog entry: %s" % data["changelog"][-1]["title"])


def command_render(data, args):
    save(data)
    print("wrote docs/todo.md and docs/todo-guides.md")


def command_check(data, args):
    validate(data)
    expected = render(data)
    actual = open(MD_PATH, encoding="utf-8").read() if os.path.exists(MD_PATH) else ""
    if expected != actual:
        raise TodoError("docs/todo.md does not match docs/todo.json: it was edited by hand or is stale. "
                        "Hand edits are not allowed (agents.md Rule 6). Run `python3 tools/todo.py render` "
                        "to write it again, then make the change with the script")
    expected_guides = render_guides(data)
    actual_guides = open(GUIDES_PATH, encoding="utf-8").read() if os.path.exists(GUIDES_PATH) else ""
    if expected_guides != actual_guides:
        raise TodoError("docs/todo-guides.md does not match docs/todo.json: it was edited by hand or is stale. "
                        "Hand edits are not allowed (agents.md Rule 6). Run `python3 tools/todo.py render`, then "
                        "change the guide with `python3 tools/todo.py guide`")
    stage_map = stages(data)
    print("ok: %d tasks (%d open, %d done), %d features, %d changelog entries" % (
        len(data["tasks"]), len(stage_map), len(data["tasks"]) - len(stage_map), len(data["features"]),
        len(data["changelog"])))


def build_parser():
    parser = argparse.ArgumentParser(
        prog="todo.py",
        description="Maintains docs/todo.json and writes docs/todo.md and docs/todo-guides.md from it. "
                    "Never edit the two generated files by hand.",
        epilog="Text options take the text itself, '@file' to read a file, or '-' to read standard input. "
               "A nested bullet inside a text is a new line that starts with two spaces: '  - text'. "
               "Every command that changes the list needs --author with the full model or person name.")
    commands = parser.add_subparsers(dest="command")

    commands.add_parser("help", help="show this help")

    sub = commands.add_parser("list", help="list tasks, one per line")
    sub.add_argument("--open", action="store_true", help="open tasks only")
    sub.add_argument("--done", action="store_true", help="finished tasks only")
    sub.add_argument("--stage", type=int, help="open tasks of one stage (0 = can start now)")
    sub.add_argument("--area", help="tasks of one area tag")
    sub.add_argument("--no-guide", action="store_true", help="open tasks that have no guide yet")

    sub = commands.add_parser("brief", help="print everything needed to build a task: the task, the finished "
                                            "tasks it rests on, its guide and the finishing steps")
    sub.add_argument("ids", nargs="+", metavar="ID")

    sub = commands.add_parser("guide", help="show, set or remove the step-by-step guide of a task")
    sub.add_argument("id", metavar="ID")
    sub.add_argument("--author")
    sub.add_argument("--text", help="the guide as Markdown without headings (use bold labels); '@file' reads a file")
    sub.add_argument("--clear", action="store_true", help="remove the guide")

    sub = commands.add_parser("show", help="print tasks in full")
    sub.add_argument("ids", nargs="+", metavar="ID")

    commands.add_parser("next-id", help="print the id the next new task gets")

    sub = commands.add_parser("add", help="add a task; it gets the next free id")
    sub.add_argument("--author", required=True)
    sub.add_argument("--area", required=True, help="area tag without brackets, e.g. Compose/script")
    sub.add_argument("--title", required=True)
    sub.add_argument("--type", required=True, choices=TASK_TYPES)
    sub.add_argument("--files", required=True, help="the files the task touches, as Markdown")
    sub.add_argument("--task", required=True, help="what is to be done")
    sub.add_argument("--needs", help="ids separated by commas, e.g. T72,T76; leave out for none")
    sub.add_argument("--status", help="an optional status line")

    sub = commands.add_parser("set", help="change fields of a task")
    sub.add_argument("id", metavar="ID")
    sub.add_argument("--author", required=True)
    sub.add_argument("--area")
    sub.add_argument("--title")
    sub.add_argument("--type", choices=TASK_TYPES)
    sub.add_argument("--files")
    sub.add_argument("--task", help="replace the task text")
    sub.add_argument("--append-task", metavar="TEXT", help="add one nested bullet to the task text")
    sub.add_argument("--status", help="set the status line; '' removes it")
    sub.add_argument("--done-text", metavar="TEXT", help="replace the text of a finished task")
    sub.add_argument("--needs", help="ids separated by commas; '' for none")

    sub = commands.add_parser("done", help="move a task to Done")
    sub.add_argument("id", metavar="ID")
    sub.add_argument("--author", required=True)
    sub.add_argument("--text", required=True, help="what was built or decided, and where it is recorded")
    sub.add_argument("--how", help="who closed it and how, e.g. 'owner accepted the proposal'; "
                                   "required for a Decision")
    sub.add_argument("--date", help="completion date YYYY-MM-DD (default: today)")
    sub.add_argument("--force", action="store_true", help="close although a need is still open")

    sub = commands.add_parser("reopen", help="move a finished task back to its stage")
    sub.add_argument("id", metavar="ID")
    sub.add_argument("--author", required=True)
    sub.add_argument("--reason", required=True)
    sub.add_argument("--task", help="the task text, when the finished task no longer has one")

    sub = commands.add_parser("feature", help="list, show, add or change a feature section")
    sub.add_argument("action", choices=("list", "show", "add", "set"))
    sub.add_argument("id", nargs="?", metavar="ID", help="feature id such as F4 (show, set)")
    sub.add_argument("--author")
    sub.add_argument("--title")
    sub.add_argument("--body", help="the whole text of the section")
    sub.add_argument("--append", metavar="TEXT", help="add one line at the end of the section")
    sub.add_argument("--replace", nargs=2, metavar=("OLD", "NEW"), help="replace a text that occurs once")

    sub = commands.add_parser("log", help="add lines to, or title, your changelog entry")
    sub.add_argument("--author", required=True)
    sub.add_argument("--title", help="the title of the entry")
    for kind in CHANGE_KINDS:
        sub.add_argument("--" + kind.lower(), action="append", metavar="TEXT")

    commands.add_parser("render", help="validate and write docs/todo.md again")
    commands.add_parser("check", help="validate docs/todo.json and confirm docs/todo.md matches it")
    return parser


HANDLERS = {"brief": command_brief, "guide": command_guide, "list": command_list, "show": command_show, "next-id": command_next_id, "add": command_add,
            "set": command_set, "done": command_done, "reopen": command_reopen, "feature": command_feature,
            "log": command_log, "render": command_render, "check": command_check}


def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command in (None, "help"):
        parser.print_help()
        return 0
    if args.command == "feature" and args.action in ("show", "set") and not args.id:
        parser.error("feature %s needs an id such as F4" % args.action)
    try:
        HANDLERS[args.command](load(), args)
    except TodoError as error:
        print("todo.py: " + str(error) + ".", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
