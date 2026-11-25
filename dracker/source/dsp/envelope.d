/**
 * File:         source/dsp/envelope.d
 * Module:       dsp.envelope
 * Phase:        Phase 1.4 — ADSR & Multi-Breakpoint Curve Envelopes
 *
 * Purpose:
 *   Implements sample-accurate ADSR envelopes and editable multi-breakpoint envelopes with curve shaping for synths, Sampler, and AdsrMod.
 *
 * Real-Time & Safety Contract:
 *   @nogc nothrow pure @safe; zero allocations, zero NaN defaults, and explicit idle/active state reporting for VoicePool deactivation.
 *
 * Dependencies:
 *   Internal: foundation.types, foundation.memory
 *   External: std.math (isFinite, pow)
 *
 * Planned API (Types, Functions & Hooks):
 *   - enum EnvStage : ubyte { idle, attack, decay, sustain, release }
 *   - struct AdsrEnvelope : prepare(), setParams(), setCurves(), trigger(), releaseNote(), next(), stage(), value(), isActive(), isReleasing(), reset()
 *   - struct EnvBreakpoint { float timeSec = 0.0f; float value = 0.0f; float curve = 1.0f; }
 *   - struct BreakpointEnvelope : prepare(), trigger(), releaseNote(), next(), isActive(), value(), reset()
 *
 * See_Also:
 *   architecture_proposal.md, dev_plan_proposal.md
 */
module dsp.envelope;

import std.math : isFinite, pow;

/**
 * Discrete stages of an ADSR envelope generator.
 */
enum EnvStage : ubyte {
    idle = 0,
    attack = 1,
    decay = 2,
    sustain = 3,
    release = 4
}

/**
 * Sample-accurate ADSR envelope with per-segment power curve shaping and legato support.
 */
struct AdsrEnvelope {
    private double sampleRate_ = 44100.0;
    private double attackSec_ = 0.005;
    private double decaySec_ = 0.1;
    private double sustainLevel_ = 0.7;
    private double releaseSec_ = 0.1;
    private double attackCurve_ = 1.0;
    private double decayCurve_ = 1.0;
    private double releaseCurve_ = 1.0;
    private EnvStage stage_ = EnvStage.idle;
    private double phase_ = 0.0;
    private double current_ = 0.0;
    private double startVal_ = 0.0;

    @nogc nothrow pure @safe:

    /**
     * Configures the envelope sample rate and preserves current parameters.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz (>= 1.0f).
     */
    void prepare(float sampleRate) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44100.0 : cast(double) sampleRate;
    }

    /**
     * Configures ADSR segment durations and sustain amplitude.
     *
     * Params:
     *   attackSec = Attack time in seconds (>= 0.0f).
     *   decaySec = Decay time in seconds (>= 0.0f).
     *   sustainLevel = Sustain level clamped to [0.0f, 1.0f].
     *   releaseSec = Release time in seconds (>= 0.0f).
     */
    void setParams(float attackSec, float decaySec, float sustainLevel, float releaseSec) {
        attackSec_ = (!isFinite(attackSec) || attackSec <= 0.0f) ? 0.0 : cast(double) attackSec;
        decaySec_ = (!isFinite(decaySec) || decaySec <= 0.0f) ? 0.0 : cast(double) decaySec;
        releaseSec_ = (!isFinite(releaseSec) || releaseSec <= 0.0f) ? 0.0 : cast(double) releaseSec;
        double sus = isFinite(sustainLevel) ? cast(double) sustainLevel : 0.0;
        if (sus < 0.0) {
            sus = 0.0;
        } else if (sus > 1.0) {
            sus = 1.0;
        }
        sustainLevel_ = sus;
    }

    /**
     * Sets segment curvature exponents (1.0 = linear; > 1.0 bends toward exponential with a slower start in
     * attack and a faster initial drop in decay and release; < 1.0 bends the opposite way).
     *
     * Params:
     *   attackCurve = Attack curve exponent clamped to [0.1f, 8.0f].
     *   decayCurve = Decay curve exponent clamped to [0.1f, 8.0f].
     *   releaseCurve = Release curve exponent clamped to [0.1f, 8.0f].
     */
    void setCurves(float attackCurve = 1.0f, float decayCurve = 1.0f, float releaseCurve = 1.0f) {
        attackCurve_ = clampCurve(attackCurve);
        decayCurve_ = clampCurve(decayCurve);
        releaseCurve_ = clampCurve(releaseCurve);
    }

    private static double clampCurve(float c) {
        if (!isFinite(c)) {
            return 1.0;
        }
        if (c < 0.1f) {
            return 0.1;
        }
        if (c > 8.0f) {
            return 8.0;
        }
        return cast(double) c;
    }

    /**
     * Starts or re-triggers the envelope attack stage.
     *
     * Params:
     *   legato = When true and already active in attack/decay/sustain, continues smoothly without resetting phase.
     */
    void trigger(bool legato = false) {
        if (legato && stage_ != EnvStage.idle && stage_ != EnvStage.release) {
            return;
        }
        startVal_ = legato ? current_ : 0.0;
        current_ = startVal_;
        phase_ = 0.0;
        if (attackSec_ <= 0.0) {
            current_ = 1.0;
            startVal_ = 1.0;
            stage_ = decaySec_ > 0.0 ? EnvStage.decay : EnvStage.sustain;
            if (stage_ == EnvStage.sustain) {
                current_ = sustainLevel_;
            }
        } else {
            stage_ = EnvStage.attack;
        }
    }

    /**
     * Transitions an active envelope into the release stage toward zero.
     */
    void releaseNote() {
        if (stage_ == EnvStage.idle || stage_ == EnvStage.release) {
            return;
        }
        startVal_ = current_;
        phase_ = 0.0;
        if (releaseSec_ <= 0.0) {
            current_ = 0.0;
            stage_ = EnvStage.idle;
        } else {
            stage_ = EnvStage.release;
        }
    }

    /**
     * Resets the envelope to idle at amplitude zero.
     */
    void reset() {
        stage_ = EnvStage.idle;
        phase_ = 0.0;
        current_ = 0.0;
        startVal_ = 0.0;
    }

    /**
     * Advances the envelope by one sample and returns the normalized envelope amplitude.
     *
     * Returns:
     *   Current amplitude in [0.0f, 1.0f].
     */
    float next() {
        final switch (stage_) {
            case EnvStage.idle:
                current_ = 0.0;
                return 0.0f;

            case EnvStage.attack: {
                immutable double inc = 1.0 / (attackSec_ * sampleRate_);
                phase_ += inc;
                if (phase_ >= 1.0) {
                    phase_ = 0.0;
                    current_ = 1.0;
                    if (decaySec_ > 0.0) {
                        stage_ = EnvStage.decay;
                    } else {
                        stage_ = EnvStage.sustain;
                        current_ = sustainLevel_;
                    }
                    return cast(float) current_;
                }
                immutable double shaped = attackCurve_ == 1.0 ? phase_ : pow(phase_, attackCurve_);
                current_ = startVal_ + (1.0 - startVal_) * shaped;
                return cast(float) current_;
            }

            case EnvStage.decay: {
                immutable double inc = 1.0 / (decaySec_ * sampleRate_);
                phase_ += inc;
                if (phase_ >= 1.0) {
                    phase_ = 0.0;
                    current_ = sustainLevel_;
                    stage_ = EnvStage.sustain;
                    return cast(float) current_;
                }
                immutable double shaped = decayCurve_ == 1.0 ? phase_ : 1.0 - pow(1.0 - phase_, decayCurve_);
                current_ = 1.0 + (sustainLevel_ - 1.0) * shaped;
                return cast(float) current_;
            }

            case EnvStage.sustain:
                current_ = sustainLevel_;
                return cast(float) current_;

            case EnvStage.release: {
                immutable double inc = 1.0 / (releaseSec_ * sampleRate_);
                phase_ += inc;
                if (phase_ >= 1.0) {
                    phase_ = 0.0;
                    current_ = 0.0;
                    stage_ = EnvStage.idle;
                    return 0.0f;
                }
                immutable double shaped = releaseCurve_ == 1.0 ? phase_ : 1.0 - pow(1.0 - phase_, releaseCurve_);
                current_ = startVal_ * (1.0 - shaped);
                return cast(float) current_;
            }
        }
    }

    /**
     * Returns the current ADSR stage.
     *
     * Returns:
     *   Active EnvStage enum value.
     */
    EnvStage stage() const {
        return stage_;
    }

    /**
     * Returns the most recently evaluated envelope amplitude without advancing state.
     *
     * Returns:
     *   Current amplitude in [0.0f, 1.0f].
     */
    float value() const {
        return cast(float) current_;
    }

    /**
     * Reports whether the envelope is active (not idle).
     *
     * Returns:
     *   True when stage != EnvStage.idle.
     */
    bool isActive() const {
        return stage_ != EnvStage.idle;
    }

    /**
     * Reports whether the envelope is currently in the release stage.
     *
     * Returns:
     *   True when stage == EnvStage.release.
     */
    bool isReleasing() const {
        return stage_ == EnvStage.release;
    }
}

/**
 * Single time-value breakpoint node for BreakpointEnvelope evaluation.
 */
struct EnvBreakpoint {
    float timeSec = 0.0f;
    float value = 0.0f;
    float curve = 1.0f;
}

/**
 * Multi-breakpoint curve envelope supporting sustain hold, loop region, and release tail.
 *
 * Evaluates an external @nogc slice of EnvBreakpoint nodes so zero GC indirections are stored.
 */
struct BreakpointEnvelope {
    private double sampleRate_ = 44100.0;
    private double elapsedSec_ = 0.0;
    private double releaseStartSec_ = 0.0;
    private double releaseStartVal_ = 0.0;
    private float current_ = 0.0f;
    private bool active_ = false;
    private bool released_ = false;
    private bool holdingSustain_ = false;
    private int sustainIdx_ = -1;
    private int loopStartIdx_ = -1;
    private int loopEndIdx_ = -1;

    @nogc nothrow pure @safe:

    /**
     * Sets the sample rate for breakpoint time progression.
     *
     * Params:
     *   sampleRate = Audio sample rate in Hertz (>= 1.0f).
     */
    void prepare(float sampleRate) {
        sampleRate_ = (!isFinite(sampleRate) || sampleRate < 1.0f) ? 44100.0 : cast(double) sampleRate;
    }

    /**
     * Triggers playback across points with optional sustain and loop breakpoint indices.
     *
     * Params:
     *   points = Monotonically ordered EnvBreakpoint array.
     *   sustainIdx = Breakpoint index where held notes pause until releaseNote(), or -1 if none.
     *   loopStartIdx = Loop start breakpoint index, or -1 if unlooped.
     *   loopEndIdx = Loop end breakpoint index (> loopStartIdx), or -1 if unlooped.
     */
    void trigger(
        const(EnvBreakpoint)[] points,
        int sustainIdx = -1,
        int loopStartIdx = -1,
        int loopEndIdx = -1
    ) {
        if (points.length == 0) {
            reset();
            return;
        }
        elapsedSec_ = 0.0;
        releaseStartSec_ = 0.0;
        released_ = false;
        holdingSustain_ = false;
        active_ = true;
        sustainIdx_ = (sustainIdx >= 0 && sustainIdx < cast(int) points.length) ? sustainIdx : -1;
        if (loopStartIdx >= 0 && loopEndIdx > loopStartIdx && loopEndIdx < cast(int) points.length) {
            loopStartIdx_ = loopStartIdx;
            loopEndIdx_ = loopEndIdx;
        } else {
            loopStartIdx_ = -1;
            loopEndIdx_ = -1;
        }
        current_ = points[0].value;
        releaseStartVal_ = current_;
    }

    /**
     * Releases a held note so evaluation advances past sustain/loop toward the final breakpoint.
     */
    void releaseNote() {
        if (!active_ || released_) {
            return;
        }
        released_ = true;
        holdingSustain_ = false;
        releaseStartSec_ = elapsedSec_;
        releaseStartVal_ = current_;
    }

    /**
     * Resets the breakpoint envelope to inactive zero amplitude.
     */
    void reset() {
        elapsedSec_ = 0.0;
        releaseStartSec_ = 0.0;
        releaseStartVal_ = 0.0;
        current_ = 0.0f;
        active_ = false;
        released_ = false;
        holdingSustain_ = false;
        sustainIdx_ = -1;
        loopStartIdx_ = -1;
        loopEndIdx_ = -1;
    }

    /**
     * Advances evaluation by one sample against points and returns the current amplitude.
     *
     * Params:
     *   points = Same EnvBreakpoint slice supplied to trigger().
     *
     * Returns:
     *   Evaluated amplitude value.
     */
    float next(const(EnvBreakpoint)[] points) {
        if (!active_ || points.length == 0) {
            active_ = false;
            current_ = 0.0f;
            return 0.0f;
        }

        if (points.length == 1) {
            if (released_) {
                active_ = false;
                current_ = 0.0f;
                return 0.0f;
            }
            current_ = points[0].value;
            return current_;
        }

        immutable double dt = 1.0 / sampleRate_;
        if (!holdingSustain_) {
            elapsedSec_ += dt;
        }

        if (!released_ && loopStartIdx_ >= 0 && loopEndIdx_ > loopStartIdx_
                && loopEndIdx_ < cast(int) points.length) {
            immutable double loopStartT = cast(double) points[loopStartIdx_].timeSec;
            immutable double loopEndT = cast(double) points[loopEndIdx_].timeSec;
            immutable double loopDur = loopEndT - loopStartT;
            if (loopDur > 0.0 && elapsedSec_ >= loopEndT) {
                immutable double over = elapsedSec_ - loopEndT;
                elapsedSec_ = loopStartT + (over - floorMod(over, loopDur));
            }
        }

        if (!released_ && sustainIdx_ >= 0 && sustainIdx_ < cast(int) points.length) {
            immutable double susT = cast(double) points[sustainIdx_].timeSec;
            if (elapsedSec_ >= susT) {
                elapsedSec_ = susT;
                holdingSustain_ = true;
                current_ = points[sustainIdx_].value;
                return current_;
            }
        }

        if (released_ && sustainIdx_ >= 0 && sustainIdx_ + 1 < cast(int) points.length) {
            immutable double susT = cast(double) points[sustainIdx_].timeSec;
            immutable double nextT = cast(double) points[sustainIdx_ + 1].timeSec;
            immutable double tailDur = nextT - susT;
            if (elapsedSec_ <= susT || releaseStartSec_ <= susT) {
                immutable double localT = elapsedSec_ - releaseStartSec_;
                if (tailDur > 0.0 && localT < tailDur) {
                    immutable double frac = localT / tailDur;
                    immutable double curve = clampPositiveCurve(points[sustainIdx_ + 1].curve);
                    immutable double shaped = curve == 1.0 ? frac : pow(frac, curve);
                    current_ = cast(float)(
                        releaseStartVal_ + (cast(double) points[sustainIdx_ + 1].value - releaseStartVal_) * shaped
                    );
                    return current_;
                }
                elapsedSec_ = nextT + (localT - tailDur);
            }
        }

        immutable double endT = cast(double) points[$ - 1].timeSec;
        if (elapsedSec_ >= endT) {
            current_ = points[$ - 1].value;
            active_ = false;
            return current_;
        }

        size_t segIdx = 0;
        while (segIdx + 1 < points.length && cast(double) points[segIdx + 1].timeSec <= elapsedSec_) {
            segIdx++;
        }
        if (segIdx + 1 >= points.length) {
            current_ = points[$ - 1].value;
            active_ = false;
            return current_;
        }

        immutable double t0 = cast(double) points[segIdx].timeSec;
        immutable double t1 = cast(double) points[segIdx + 1].timeSec;
        immutable double span = t1 - t0;
        if (span <= 0.0) {
            current_ = points[segIdx + 1].value;
            return current_;
        }

        double frac = (elapsedSec_ - t0) / span;
        if (frac < 0.0) {
            frac = 0.0;
        } else if (frac > 1.0) {
            frac = 1.0;
        }
        immutable double curve = clampPositiveCurve(points[segIdx + 1].curve);
        immutable double shaped = curve == 1.0 ? frac : pow(frac, curve);
        immutable double v0 = cast(double) points[segIdx].value;
        immutable double v1 = cast(double) points[segIdx + 1].value;
        current_ = cast(float)(v0 + (v1 - v0) * shaped);
        return current_;
    }

    private static double floorMod(double x, double period) {
        immutable long k = cast(long)(x / period);
        return x - cast(double) k * period;
    }

    private static double clampPositiveCurve(float c) {
        if (!isFinite(c)) {
            return 1.0;
        }
        if (c < 0.1f) {
            return 0.1;
        }
        if (c > 8.0f) {
            return 8.0;
        }
        return cast(double) c;
    }

    /**
     * Reports whether the breakpoint envelope is still advancing or sustaining.
     *
     * Returns:
     *   True if active.
     */
    bool isActive() const {
        return active_;
    }

    /**
     * Returns the most recently evaluated breakpoint amplitude.
     *
     * Returns:
     *   Current amplitude value.
     */
    float value() const {
        return current_;
    }
}
