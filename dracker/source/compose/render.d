/**
 * File:         source/compose/render.d
 * Module:       compose.render
 * Phase:        Composition helper (dracker-compose) — T86 (Offline render and report)
 *
 * Purpose:
 *   Plays a LoadedProject offline through StudioSession and writes a 32-bit IEEE float stereo WAV,
 *   sharing the sound-check offline render helper with source/main.d. When rendering with a full report
 *   (for `dracker-compose render`), computes total length, overall peak and RMS average level, per-bar
 *   peak/average levels and silent bar indices, the bars where the master soft limiter worked (output above
 *   LIMITER_KNEE), and per-module sound activity in both plain text and JSON forms. The report render plays the
 *   arrangement once from the start to its end and does not follow the project's loop (T118).
 *
 * Real-Time & Safety Contract:
 *   Off-RT only. Runs an isolated headless StudioSession per render and releases it on exit.
 *
 * Dependencies:
 *   Internal: app.session (StudioSession), compose_main (JsonWriter), foundation.memory (OwnedBuffer),
 *             modules.output (LIMITER_KNEE),
 *             foundation.types (FIXED_BLOCK_FRAMES), io.audio_io (writeWavFile), io.project_format
 *             (isValidTimeSignature, LoadedProject), sequencer.engine (EngineTelemetry)
 *   External: std.format (format), std.math (fabs, sqrt)
 *
 * Planned API (Types, Functions & Hooks):
 *   - struct BarLevelReport; struct ModuleSoundReport; struct RenderReport; struct RenderResult
 *   - renderProjectToWav()
 *   - renderProjectWithReport()
 *   - renderReportText(); renderReportJson()
 *
 * See_Also:
 *   docs/todo.md (T66, T86, T118), source/main.d, source/compose_main.d
 */
module compose.render;

import std.format : format;
import std.math : fabs, sqrt;

import app.session : StudioSession;
import compose_main : JsonWriter;
import foundation.memory : OwnedBuffer;
import foundation.types : FIXED_BLOCK_FRAMES;
import io.audio_io : writeWavFile;
import io.project_format : isValidTimeSignature, LoadedProject;
import modules.output : LIMITER_KNEE;
import sequencer.engine : EngineTelemetry;

/**
 * Measured level statistics for a single 1-based song bar.
 */
struct BarLevelReport {
    uint bar = 1;
    float peak = 0.0f;
    float rms = 0.0f;
    bool silent = true;
    bool limited = false;
}

/**
 * Sound activity summary for one module in the rendered project.
 */
struct ModuleSoundReport {
    uint id = 0;
    string typeId = "";
    string name = "";
    float peak = 0.0f;
    bool producedSound = false;
}

/**
 * Complete offline render report produced by renderProjectWithReport().
 */
struct RenderReport {
    string wavPath = "";
    uint sampleRate = 44_100;
    double lengthSeconds = 0.0;
    size_t totalFrames = 0;
    uint arrangementBars = 0;
    float peak = 0.0f;
    float rms = 0.0f;
    bool limiterReached = false;
    uint[] limiterBars;
    bool loopIgnored = false;
    long loopStartLine = 0;
    long loopEndLine = 0;
    uint[] silentBars;
    BarLevelReport[] bars;
    ModuleSoundReport[] modules;
}

/**
 * Outcome of rendering a project and computing its diagnostic report.
 */
struct RenderResult {
    bool ok = false;
    RenderReport report;
    string error = "";
}

private float clampSampleAbs(float v) @safe pure nothrow @nogc {
    immutable float av = fabs(v);
    return av;
}

private uint projectLinesPerBar(const ref LoadedProject proj) @safe pure nothrow @nogc {
    if (!isValidTimeSignature(proj.timeSigNumerator, proj.timeSigDenominator)) {
        return 16;
    }
    return cast(uint) proj.timeSigNumerator * (16u / cast(uint) proj.timeSigDenominator);
}

private long projectArrangementLines(const ref LoadedProject proj, uint linesPerBar) @safe pure nothrow @nogc {
    long endLine = 0;
    foreach (ref clip; proj.clips) {
        immutable long ce = clip.startLine + clip.lengthLines;
        if (ce > endLine) {
            endLine = ce;
        }
    }
    if (proj.loopEndLine > endLine) {
        endLine = proj.loopEndLine;
    }
    if (endLine <= 0) {
        endLine = cast(long) linesPerBar;
    }
    return endLine;
}

/**
 * Renders a project from line 0 offline at 44.1 kHz for `seconds` and writes a stereo WAV file.
 * Shared with source/main.d's `--sound-check` and `--sound-check-presets`.
 *
 * Params:
 *   proj = Project document to render.
 *   seconds = Total render duration in seconds.
 *   path = Destination .wav path.
 *   peak = Receives highest absolute sample amplitude across both channels.
 *   err = Receives failure diagnostic if initialization, activation, render, or WAV write fails.
 *
 * Returns:
 *   True on success.
 */
bool renderProjectToWav(const ref LoadedProject proj, double seconds, string path, out float peak,
        out string err) {
    enum uint rate = 44_100;
    StudioSession s = new StudioSession();
    if (!s.initialize(cast(float) rate)) {
        err = "Session initialization failed";
        return false;
    }
    scope (exit) s.shutdown();
    if (!s.openProjectFromMemory(proj, err)) {
        err = "Could not build the preview project: " ~ err;
        return false;
    }
    s.engine().reset();
    s.engine().setTempo(proj.bpm, proj.ticksPerLine);
    s.engine().seekLine(0);
    s.engine().setPlaying(true);
    immutable size_t frames = (cast(size_t)(seconds * rate) / 64 + 1) * 64;
    OwnedBuffer!float l;
    OwnedBuffer!float r;
    if (!s.engine().renderOfflineToBuffer(frames, 64, l, r)) {
        err = "Offline render failed";
        return false;
    }
    peak = 0.0f;
    foreach (i; 0 .. l.length) {
        peak = fabs(l[i]) > peak ? fabs(l[i]) : peak;
        peak = fabs(r[i]) > peak ? fabs(r[i]) : peak;
    }
    const(float)[][2] channels = [l[], r[]];
    if (!writeWavFile(path, channels[], rate, err)) {
        err = "Could not write " ~ path ~ ": " ~ err;
        return false;
    }
    return true;
}

/**
 * Renders a project from line 0 through the end of its arrangement plus tailSeconds, writes a WAV
 * file, and measures per-bar levels, silent bars, overall peak/RMS, limiter activity, and per-module sound.
 * The arrangement is played once: the project's loop is switched off for the render, so a loop that ends
 * before the arrangement does not repeat (T118). The limiter counts as working in a bar when an output
 * sample there is above LIMITER_KNEE.
 *
 * Params:
 *   proj = Project document to render.
 *   wavPath = Destination .wav path.
 *   tailSeconds = Extra tail duration rendered after the arrangement ends (default 2.0 s).
 *   sampleRate = Sample rate in Hz (default 44,100).
 *
 * Returns:
 *   RenderResult with ok=true and full RenderReport on success.
 */
RenderResult renderProjectWithReport(const ref LoadedProject proj, string wavPath, double tailSeconds = 2.0,
        uint sampleRate = 44_100) {
    RenderResult res;
    if (wavPath.length == 0) {
        res.error = "Output WAV path cannot be empty";
        return res;
    }
    if (tailSeconds < 0.0) {
        tailSeconds = 0.0;
    }
    if (sampleRate == 0) {
        sampleRate = 44_100;
    }

    immutable uint lpb = projectLinesPerBar(proj);
    immutable long arrLines = projectArrangementLines(proj, lpb);
    immutable uint arrBars = cast(uint)((arrLines + lpb - 1) / lpb);
    immutable double secPerLine = (proj.bpm > 0.0 && proj.ticksPerLine > 0)
        ? cast(double) proj.ticksPerLine * 2.5 / proj.bpm
        : 0.125;
    immutable double songSec = cast(double) arrLines * secPerLine;
    immutable double totalSec = songSec + tailSeconds;
    size_t rawFrames = cast(size_t)(totalSec * sampleRate + 0.5);
    if (rawFrames < FIXED_BLOCK_FRAMES) {
        rawFrames = FIXED_BLOCK_FRAMES;
    }
    immutable size_t totalFrames = ((rawFrames + FIXED_BLOCK_FRAMES - 1) / FIXED_BLOCK_FRAMES) * FIXED_BLOCK_FRAMES;

    StudioSession s = new StudioSession();
    if (!s.initialize(cast(float) sampleRate)) {
        res.error = "Session initialization failed";
        return res;
    }
    scope (exit) s.shutdown();

    string err;
    if (!s.openProjectFromMemory(proj, err)) {
        res.error = "Could not open project for render: " ~ err;
        return res;
    }
    if (!s.doSetLoop(0, 0)) {
        res.error = "Could not switch the loop off for the render";
        return res;
    }

    float[] outL = new float[totalFrames];
    float[] outR = new float[totalFrames];
    float[] modPeakByIndex = new float[proj.modules.length];
    modPeakByIndex[] = 0.0f;

    s.engine().reset();
    s.engine().setTempo(proj.bpm, proj.ticksPerLine);
    s.engine().seekLine(0);
    s.engine().setPlaying(true);

    const(float[])[2] emptyIn = [null, null];
    EngineTelemetry tel;

    size_t pos = 0;
    while (pos < totalFrames) {
        float[][2] outs = [
            outL[pos .. pos + FIXED_BLOCK_FRAMES],
            outR[pos .. pos + FIXED_BLOCK_FRAMES]
        ];
        s.engine().processHostBuffer(outs, emptyIn, FIXED_BLOCK_FRAMES);
        if (s.engine().readTelemetry(tel)) {
            immutable size_t count = tel.graph.moduleCount < tel.graph.modulePeaks.length
                ? tel.graph.moduleCount : tel.graph.modulePeaks.length;
            foreach (ti; 0 .. count) {
                immutable uint mId = tel.graph.moduleIds[ti];
                immutable float mp = tel.graph.modulePeaks[ti];
                foreach (mi, ref pm; proj.modules) {
                    if (pm.id == mId && mp > modPeakByIndex[mi]) {
                        modPeakByIndex[mi] = mp;
                    }
                }
            }
        }
        pos += FIXED_BLOCK_FRAMES;
    }
    s.engine().setPlaying(false);

    const(float)[][2] channels = [outL[], outR[]];
    if (!writeWavFile(wavPath, channels[], sampleRate, err)) {
        res.error = "Could not write " ~ wavPath ~ ": " ~ err;
        return res;
    }

    double totalSq = 0.0;
    float overallPeak = 0.0f;
    foreach (i; 0 .. totalFrames) {
        immutable float al = clampSampleAbs(outL[i]);
        immutable float ar = clampSampleAbs(outR[i]);
        if (al > overallPeak) overallPeak = al;
        if (ar > overallPeak) overallPeak = ar;
        totalSq += cast(double) outL[i] * outL[i] + cast(double) outR[i] * outR[i];
    }
    immutable float overallRms = cast(float) sqrt(totalSq / cast(double)(totalFrames * 2));

    immutable double framesPerBar = cast(double) lpb * secPerLine * cast(double) sampleRate;
    BarLevelReport[] bars = new BarLevelReport[arrBars];
    uint[] silentBars;
    uint[] limiterBars;
    foreach (b; 0 .. arrBars) {
        size_t fStart = cast(size_t)(cast(double) b * framesPerBar);
        size_t fEnd = cast(size_t)(cast(double)(b + 1) * framesPerBar);
        if (fStart > totalFrames) fStart = totalFrames;
        if (fEnd > totalFrames) fEnd = totalFrames;
        float barPeak = 0.0f;
        double barSq = 0.0;
        size_t n = 0;
        foreach (i; fStart .. fEnd) {
            immutable float al = clampSampleAbs(outL[i]);
            immutable float ar = clampSampleAbs(outR[i]);
            if (al > barPeak) barPeak = al;
            if (ar > barPeak) barPeak = ar;
            barSq += cast(double) outL[i] * outL[i] + cast(double) outR[i] * outR[i];
            n++;
        }
        immutable float barRms = n > 0 ? cast(float) sqrt(barSq / cast(double)(n * 2)) : 0.0f;
        immutable bool isSilent = barPeak <= 1e-5f;
        immutable bool isLimited = barPeak > LIMITER_KNEE;
        bars[b] = BarLevelReport(b + 1, barPeak, barRms, isSilent, isLimited);
        if (isSilent) {
            silentBars ~= b + 1;
        }
        if (isLimited) {
            limiterBars ~= b + 1;
        }
    }

    ModuleSoundReport[] modReports;
    modReports.reserve(proj.modules.length);
    foreach (mi, ref pm; proj.modules) {
        immutable float mp = modPeakByIndex[mi];
        modReports ~= ModuleSoundReport(pm.id, pm.typeId, pm.name, mp, mp > 1e-5f);
    }

    RenderReport rep;
    rep.wavPath = wavPath;
    rep.sampleRate = sampleRate;
    rep.lengthSeconds = cast(double) totalFrames / cast(double) sampleRate;
    rep.totalFrames = totalFrames;
    rep.arrangementBars = arrBars;
    rep.peak = overallPeak;
    rep.rms = overallRms;
    rep.limiterReached = overallPeak > LIMITER_KNEE;
    rep.limiterBars = limiterBars;
    rep.loopStartLine = proj.loopStartLine;
    rep.loopEndLine = proj.loopEndLine;
    rep.loopIgnored = proj.loopEndLine > proj.loopStartLine
        && (proj.loopStartLine != 0 || proj.loopEndLine < arrLines);
    rep.silentBars = silentBars;
    rep.bars = bars;
    rep.modules = modReports;

    res.ok = true;
    res.report = rep;
    return res;
}

/**
 * Formats a RenderReport as human-readable plain text.
 *
 * Params:
 *   r = RenderReport returned by renderProjectWithReport().
 *
 * Returns:
 *   Formatted multi-line text summary.
 */
string renderReportText(const ref RenderReport r) @safe nothrow {
    string txt;
    try {
        txt ~= format("Rendered: %s (%.2f s, %d Hz, %d bars, the arrangement once from start to end)\n",
            r.wavPath, r.lengthSeconds, r.sampleRate, r.arrangementBars);
        if (r.loopIgnored) {
            txt ~= format("Loop:     lines %d to %d, not followed by the render\n", r.loopStartLine, r.loopEndLine);
        }
        txt ~= format("Levels:   peak %.4f  average %.4f  limiter %s\n",
            r.peak, r.rms, limiterText(r));
        if (r.silentBars.length == 0) {
            txt ~= "Silent bars: none\n";
        } else {
            txt ~= "Silent bars:";
            foreach (idx, b; r.silentBars) {
                txt ~= format(idx > 0 ? ", %d" : " %d", b);
            }
            txt ~= "\n";
        }
        txt ~= "Bars:\n";
        foreach (ref b; r.bars) {
            txt ~= format("  bar %d: peak %.4f  avg %.4f%s%s\n",
                b.bar, b.peak, b.rms, b.silent ? " (silent)" : "", b.limited ? " (limiter)" : "");
        }
        txt ~= "Modules:\n";
        foreach (ref m; r.modules) {
            txt ~= format("  %-18s (%s): peak %.4f (%s)\n",
                m.name, m.typeId, m.peak, m.producedSound ? "sound" : "silent");
        }
    } catch (Exception) {
        txt = "Rendered: " ~ r.wavPath ~ "\n";
    }
    return txt;
}

/**
 * Describes the limiter result of a report: "not engaged", or the bars where it worked.
 *
 * Params:
 *   r = RenderReport returned by renderProjectWithReport().
 *
 * Returns:
 *   For example "engaged in 2 bars (3, 4)", or "engaged after the arrangement" for a tail-only peak.
 */
private string limiterText(const ref RenderReport r) @safe pure nothrow {
    if (!r.limiterReached) {
        return "not engaged";
    }
    if (r.limiterBars.length == 0) {
        return "engaged after the arrangement";
    }
    string list;
    foreach (i, b; r.limiterBars) {
        list ~= (i > 0 ? ", " : "") ~ wholeNumber(b);
    }
    return "engaged in " ~ wholeNumber(cast(uint) r.limiterBars.length)
        ~ (r.limiterBars.length == 1 ? " bar (" : " bars (") ~ list ~ ")";
}

/**
 * Writes a whole number in decimal.
 *
 * Params:
 *   v = The number.
 *
 * Returns:
 *   Its decimal digits.
 */
private string wholeNumber(uint v) @safe pure nothrow {
    if (v == 0) {
        return "0";
    }
    char[10] buf;
    size_t n = buf.length;
    while (v > 0) {
        buf[--n] = cast(char)('0' + v % 10);
        v /= 10;
    }
    return buf[n .. $].idup;
}

/**
 * Formats a RenderReport as a JSON document with ok=true.
 *
 * Params:
 *   r = RenderReport returned by renderProjectWithReport().
 *
 * Returns:
 *   Formatted JSON string ending with newline.
 */
string renderReportJson(const ref RenderReport r) @safe pure nothrow {
    JsonWriter json = JsonWriter();
    json.beginObject();
    json.key("ok");
    json.valueBool(true);
    json.key("wav");
    json.valueString(r.wavPath);
    json.key("sampleRate");
    json.valueInt(r.sampleRate);
    json.key("lengthSeconds");
    json.valueDouble(r.lengthSeconds);
    json.key("totalFrames");
    json.valueInt(cast(long) r.totalFrames);
    json.key("arrangementBars");
    json.valueInt(r.arrangementBars);
    json.key("peak");
    json.valueDouble(r.peak);
    json.key("rms");
    json.valueDouble(r.rms);
    json.key("limiterReached");
    json.valueBool(r.limiterReached);
    json.key("limiterBars");
    json.beginArray();
    foreach (b; r.limiterBars) {
        json.valueInt(b);
    }
    json.endArray();
    json.key("playback");
    json.valueString("once");
    json.key("loop");
    json.beginObject();
    json.key("start");
    json.valueInt(r.loopStartLine);
    json.key("end");
    json.valueInt(r.loopEndLine);
    json.key("followed");
    json.valueBool(false);
    json.endObject();
    json.key("silentBars");
    json.beginArray();
    foreach (b; r.silentBars) {
        json.valueInt(b);
    }
    json.endArray();
    json.key("bars");
    json.beginArray();
    foreach (ref b; r.bars) {
        json.beginObject();
        json.key("bar");
        json.valueInt(b.bar);
        json.key("peak");
        json.valueDouble(b.peak);
        json.key("rms");
        json.valueDouble(b.rms);
        json.key("silent");
        json.valueBool(b.silent);
        json.key("limited");
        json.valueBool(b.limited);
        json.endObject();
    }
    json.endArray();
    json.key("modules");
    json.beginArray();
    foreach (ref m; r.modules) {
        json.beginObject();
        json.key("id");
        json.valueInt(m.id);
        json.key("typeId");
        json.valueString(m.typeId);
        json.key("name");
        json.valueString(m.name);
        json.key("peak");
        json.valueDouble(m.peak);
        json.key("producedSound");
        json.valueBool(m.producedSound);
        json.endObject();
    }
    json.endArray();
    json.endObject();
    return json.text() ~ "\n";
}
