/**
 * File:         source/gui/views/script_view.d
 * Module:       gui.views.script_view
 * Phase:        Pattern editor views — T112 (Script tab: the view), T113 (applying a script)
 *
 * Purpose:
 *   The fourth tab ("Script") of PatternEditorView (decision T108): offered for every normal and drum
 *   pattern so the user can edit a composition script in a TextArea, inspect the active project's module
 *   handles, and run Apply (or Cmd+Return). Apply (T113, decisions T108 and T109) starts an interpreter from
 *   a snapshot of the open project, refuses `project`, `open` and `save`, resolves relative paths against the
 *   project's folder, and runs every line in the interpreter's check mode, so nothing is written while the
 *   script runs. Only when every line succeeded are the presets written by `savemodule` saved and the result
 *   swapped in as one undo step ("Apply script"); the input is then cleared. When any line fails, nothing
 *   changes: the input is kept, the problem is listed with line and column and its line is marked. Apply runs
 *   through a replaceable hook (applyHook) so tests and later front ends can substitute it.
 *
 * Real-Time & Safety Contract:
 *   UI thread only. Reads module list from ctx.session.document() and renders with StudioTheme tokens.
 *
 * Dependencies:
 *   Internal: app.keymap (StudioAction, StudioCommandSink), compose.project_writer (OUTPUT_HANDLE,
 *             OUTPUT_TYPE_ID, suggestedHandle), compose.script.commands (createDefaultInterpreter),
 *             compose.script.interpreter (RunResult, ScriptInterpreter, ScriptProblem), gui.renderer
 *             (FontId, IRenderer2D, ITextMeasurer, Point2F, RectF), gui.theme (StudioTheme),
 *             gui.views.studio_context (StudioContext), gui.widgets (Button, lineHeightOr, TextArea,
 *             Widget), io.project_format (LoadedProject), compose.project_writer (ProjectWriter)
 *   External: std.file (write), std.format (format), std.path (dirName)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct ScriptApplyResult; alias ScriptApplyHook
 *   - class ScriptView : Widget, StudioCommandSink
 *     (editor, applyButton, applyHook, projectHandles(), apply(), applyToSession(), checkScript(), message(),
 *     lastOk(), lastProblems())
 *   - enum APPLY_UNDO_LABEL
 *
 * See_Also:
 *   docs/todo.md (T83, T103, T108, T109, T110, T111, T112, T113), source/gui/views/pattern_editor.d, source/gui/widgets.d
 */
module gui.views.script_view;

import std.file : write;
import std.format : format;
import std.path : dirName;

import app.keymap : StudioAction, StudioCommandSink;
import compose.project_writer : ProjectDocumentResult, ProjectOpenResult, ProjectWriter;
import compose.script.commands : createDefaultInterpreter, createInterpreterFromDocument, restrictForApp,
    ScriptOpenResult;
import compose.script.interpreter : RunResult, ScriptInterpreter, ScriptProblem;
import gui.renderer : FontId, IRenderer2D, ITextMeasurer, Point2F, RectF;
import gui.theme : StudioTheme;
import gui.views.studio_context : StudioContext;
import gui.widgets : Button, lineHeightOr, TextArea, Widget;
import io.project_format : LoadedProject;

/**
 * The undo menu label of an applied script (T109).
 */
enum string APPLY_UNDO_LABEL = "Apply script";

/**
 * Result returned by ScriptView's applyHook: the live apply of T113, or a check-only run (checkOnly true, the
 * project is not changed and the input is kept).
 */
struct ScriptApplyResult {
    bool ok = false;
    size_t commandsRun = 0;
    ScriptProblem[] problems;
    string message = "";
    bool checkOnly = false;
    string[] warnings;
}

/** Delegate executed when the user clicks Apply or presses Cmd+Return. */
alias ScriptApplyHook = ScriptApplyResult delegate(string source);

/**
 * Pattern editor's fourth tab holding a TextArea, Apply button, project handle strip, and status bar.
 */
final class ScriptView : Widget, StudioCommandSink {
    enum float TOP_BAR_H = 30.0f;
    enum float STATUS_BAR_H = 26.0f;

    StudioContext ctx;
    TextArea editor;
    Button applyButton;
    ScriptApplyHook applyHook;

    private string message_ = "Type script lines and press Apply (Cmd+Return). Cmd+Z takes an applied script back.";
    private bool lastOk_ = true;
    private ScriptProblem[] lastProblems_;
    private string[] handles_;
    private ulong handlesRevision_ = ulong.max;

    /**
     * Builds the Script tab view over ctx with default check-only script validation.
     *
     * Params:
     *   ctx = Shared studio context.
     */
    this(StudioContext ctx) {
        this.ctx = ctx;
        id = "pattern.script";
        editor = add(new TextArea());
        editor.id = "script.editor";
        editor.onSubmit = () { apply(); };
        if (ctx !is null && ctx.clipboard !is null) {
            editor.clipboardRead = () { return ctx.clipboard.getText(); };
            editor.clipboardWrite = (string text) { return ctx.clipboard.setText(text); };
        }
        applyButton = add(new Button("Apply", &onApplyClicked));
        applyButton.id = "script.apply";
        applyHook = (string source) { return applyToSession(source); };
    }

    /**
     * Returns the handles a script uses for the open project's modules: the ones the interpreter derives when
     * it starts from the document ("out" for the Master Output), cached until the document changes.
     *
     * Returns:
     *   Handles in document order; empty when there is no session.
     */
    string[] projectHandles() {
        if (ctx is null || ctx.session is null) {
            return null;
        }
        immutable ulong revision = ctx.session.documentRevision();
        if (revision != handlesRevision_) {
            handles_ = null;
            ProjectOpenResult opened = ProjectWriter.fromLoadedProject(*ctx.session.document());
            if (opened.ok) {
                foreach (ref h; opened.handles) {
                    handles_ ~= h.handle;
                }
            }
            handlesRevision_ = revision;
        }
        return handles_;
    }

    /**
     * Applies a script to the open project (T113): runs every line against a snapshot of the document and,
     * only when all of them succeed, writes the presets `savemodule` asked for and replaces the document as
     * one undo step. `project`, `open` and `save` are refused; relative paths are read from the project's
     * folder and refused while the project has not been saved.
     *
     * Params:
     *   source = The script text.
     *
     * Returns:
     *   ok with the number of commands applied, or the problems (nothing was changed).
     */
    ScriptApplyResult applyToSession(string source) {
        ScriptApplyResult result;
        if (ctx is null || ctx.session is null) {
            return checkScript(source);
        }
        LoadedProject snapshot;
        string err;
        if (!ctx.session.snapshotDocumentForSave(snapshot, err)) {
            result.message = "Could not read the open project: " ~ err;
            return result;
        }
        ScriptOpenResult opened = createInterpreterFromDocument(snapshot, true);
        if (!opened.ok) {
            result.problems = [opened.problem];
            return result;
        }
        ScriptInterpreter interp = opened.interpreter;
        immutable string projectPath = ctx.session.currentPath();
        restrictForApp(interp, projectPath.length > 0 ? dirName(projectPath) : "");
        RunResult run = interp.runScript(source);
        result.commandsRun = run.commandsRun;
        if (!run.ok) {
            result.problems = run.problems;
            return result;
        }
        if (run.commandsRun == 0) {
            result.ok = true;
            result.message = "Nothing to apply.";
            return result;
        }
        ProjectDocumentResult built = interp.buildDocument();
        if (!built.ok) {
            result.message = "The script ran, but the project could not be built: " ~ built.problem.reason;
            return result;
        }
        foreach (path; interp.savedPaths()) {
            const(ubyte)[] bytes;
            if (!interp.findVirtualPreset(path, bytes)) {
                continue;
            }
            if (!writePresetBytes(path, bytes, err)) {
                result.message = "Nothing was applied: could not write the preset '" ~ path ~ "': " ~ err;
                return result;
            }
        }
        if (!ctx.session.doReplaceDocument(built.project, APPLY_UNDO_LABEL, err)) {
            result.message = "Nothing was applied: " ~ err;
            return result;
        }
        result.ok = true;
        result.warnings = run.warnings;
        result.message = format("Applied %d %s. Cmd+Z takes the script back.", run.commandsRun,
            run.commandsRun == 1 ? "command" : "commands") ~ warningText(run.warnings);
        return result;
    }

    /**
     * Runs the active applyHook over editor.text() and shows the outcome: on success the input is cleared
     * (unless the hook only checked the script or there was nothing to apply), on failure the input is kept,
     * the first problem's line is marked and every problem is listed.
     *
     * Returns:
     *   ScriptApplyResult returned by applyHook.
     */
    ScriptApplyResult apply() {
        ScriptApplyResult res;
        if (applyHook !is null) {
            res = applyHook(editor.text());
        } else {
            res = applyToSession(editor.text());
        }
        lastOk_ = res.ok;
        lastProblems_ = res.problems;
        if (!res.ok) {
            if (res.problems.length > 0) {
                immutable size_t lineIdx = res.problems[0].line > 0 ? res.problems[0].line - 1 : 0;
                editor.markLine(lineIdx);
                string summary;
                foreach (i, ref p; res.problems) {
                    if (i > 0) {
                        summary ~= " | ";
                    }
                    summary ~= p.text();
                }
                message_ = summary;
            } else {
                editor.markLine(TextArea.NO_MARK);
                message_ = res.message.length > 0 ? res.message : "Script check failed.";
            }
        } else {
            editor.markLine(TextArea.NO_MARK);
            message_ = res.message.length > 0 ? res.message
                : format("%d %s valid (check only)", res.commandsRun,
                    res.commandsRun == 1 ? "command" : "commands");
            if (res.commandsRun > 0 && !res.checkOnly) {
                editor.clear();
            }
        }
        invalidate();
        return res;
    }

    /**
     * Returns the current message shown in the bottom status strip.
     *
     * Returns:
     *   Status or problem text.
     */
    string message() const {
        return message_;
    }

    /**
     * Reports whether the most recent apply() succeeded.
     *
     * Returns:
     *   True if valid or not yet run with errors.
     */
    bool lastOk() const {
        return lastOk_;
    }

    /**
     * Returns the structured problems from the most recent apply() call.
     *
     * Returns:
     *   Slice of ScriptProblems (empty when valid).
     */
    const(ScriptProblem)[] lastProblems() const {
        return lastProblems_;
    }

    /**
     * Allows document-level shortcuts to pass through rather than being swallowed as tracker edits.
     *
     * Params:
     *   action = Resolved StudioAction.
     *
     * Returns:
     *   False.
     */
    bool handleStudioAction(StudioAction action) {
        cast(void) action;
        return false;
    }

    override void layoutChildren() {
        immutable float pad = 6.0f;
        immutable float btnW = 72.0f;
        immutable float btnH = TOP_BAR_H - 6.0f;
        applyButton.arrange(RectF(bounds.right() - pad - btnW, bounds.y + 3.0f, btnW, btnH));
        immutable float edTop = bounds.y + TOP_BAR_H;
        immutable float edH = bounds.h - TOP_BAR_H - STATUS_BAR_H;
        editor.arrange(RectF(bounds.x, edTop, bounds.w, edH > 0.0f ? edH : 0.0f));
    }

    override void paint(IRenderer2D r, const ref StudioTheme theme) {
        r.fillRect(bounds, theme.panel);

        immutable RectF topBar = RectF(bounds.x, bounds.y, bounds.w, TOP_BAR_H);
        r.fillRect(topBar, theme.panelRaised);
        r.fillRect(RectF(bounds.x, topBar.bottom() - 1.0f, bounds.w, 1.0f), theme.border);

        const(string)[] handles = projectHandles();
        string handleLabel = "Handles:";
        foreach (i, h; handles) {
            handleLabel ~= (i > 0 ? ", " : " ") ~ h;
        }
        immutable float lh = lineHeightOr(null, FontId.ui, theme.fontSizeSmall);
        r.drawText(Point2F(bounds.x + 8.0f, bounds.y + (TOP_BAR_H - lh) * 0.5f),
            handleLabel, FontId.ui, theme.fontSizeSmall, theme.textDim);

        super.paint(r, theme);

        immutable RectF statusBar = RectF(bounds.x, bounds.bottom() - STATUS_BAR_H, bounds.w, STATUS_BAR_H);
        r.fillRect(statusBar, theme.panelRaised);
        r.fillRect(RectF(bounds.x, statusBar.y, bounds.w, 1.0f), theme.border);
        r.drawText(Point2F(bounds.x + 8.0f, statusBar.y + (STATUS_BAR_H - lh) * 0.5f),
            message_, FontId.ui, theme.fontSizeSmall, lastOk_ ? theme.text : theme.danger);
    }

    private void onApplyClicked() {
        apply();
    }

    /**
     * Checks a script without a project (an empty one) and without changing anything.
     *
     * Params:
     *   source = The script text.
     *
     * Returns:
     *   The outcome with checkOnly set.
     */
    static ScriptApplyResult checkScript(string source) {
        ScriptInterpreter interp = createDefaultInterpreter(true);
        RunResult res = interp.runScript(source);
        ScriptApplyResult outRes;
        outRes.checkOnly = true;
        outRes.ok = res.ok;
        outRes.commandsRun = res.commandsRun;
        outRes.problems = res.problems;
        if (res.ok) {
            outRes.warnings = res.warnings;
            outRes.message = format("%d %s valid (check only)", res.commandsRun,
                res.commandsRun == 1 ? "command" : "commands") ~ warningText(res.warnings);
        }
        return outRes;
    }

    /**
     * Writes the warnings of a successful run for the status strip (T117).
     *
     * Params:
     *   warnings = Warning sentences.
     *
     * Returns:
     *   " Warning: a; b." or "" without warnings.
     */
    static string warningText(const(string)[] warnings) @safe pure nothrow {
        if (warnings.length == 0) {
            return "";
        }
        string text = warnings.length == 1 ? " Warning: " : " Warnings: ";
        foreach (i, w; warnings) {
            text ~= (i > 0 ? "; " : "") ~ w;
        }
        return text ~ ".";
    }

    /**
     * Writes the bytes of a preset file. std.file.write is not @safe or nothrow; its exception becomes err.
     *
     * Params:
     *   path = Destination path.
     *   bytes = The .msym bytes.
     *   err = Receives the reason on failure.
     *
     * Returns:
     *   True when the file was written.
     */
    private static bool writePresetBytes(string path, const(ubyte)[] bytes, out string err) {
        try {
            write(path, bytes);
            return true;
        } catch (Exception ex) {
            err = ex.msg;
            return false;
        }
    }
}
