// @vitest-environment node
// In-call lifecycle state machine: armed only when joined; pre-join preview
// produces nothing; leave / pagehide → final flush callback.
import { describe, it, expect, vi } from "vitest";
import C from "../src/content.js";

function harness(initialInCall = false) {
  let inCall = initialInCall;
  const onJoin = vi.fn();
  const onLeave = vi.fn();
  const lc = C.createLifecycle({ isInCall: () => inCall, onJoin, onLeave });
  return { lc, onJoin, onLeave, setInCall: (v) => (inCall = v) };
}

describe("createLifecycle", () => {
  it("stays idle (produces nothing) while pre-join", () => {
    const { lc, onJoin, onLeave } = harness(false);
    lc.poll();
    lc.poll();
    expect(lc.state).toBe("idle");
    expect(onJoin).not.toHaveBeenCalled();
    expect(onLeave).not.toHaveBeenCalled();
  });

  it("arms exactly once on join", () => {
    const { lc, onJoin, setInCall } = harness(false);
    setInCall(true);
    lc.poll();
    lc.poll();
    lc.poll();
    expect(lc.state).toBe("in-call");
    expect(onJoin).toHaveBeenCalledTimes(1);
  });

  it("fires the final flush on leave detection", () => {
    const { lc, onLeave, setInCall } = harness(false);
    setInCall(true);
    lc.poll();
    setInCall(false);
    lc.poll();
    expect(lc.state).toBe("idle");
    expect(onLeave).toHaveBeenCalledTimes(1);
    expect(onLeave).toHaveBeenCalledWith({ final: false });
  });

  it("pagehide while in-call → terminal final flush", () => {
    const { lc, onLeave, setInCall } = harness(false);
    setInCall(true);
    lc.poll();
    lc.pagehide();
    expect(onLeave).toHaveBeenCalledWith({ final: true });
    expect(lc.state).toBe("idle");
  });

  it("pagehide while idle is a no-op", () => {
    const { lc, onLeave } = harness(false);
    lc.pagehide();
    expect(onLeave).not.toHaveBeenCalled();
  });

  it("supports rejoin after leave (idle → in-call again)", () => {
    const { lc, onJoin, setInCall } = harness(false);
    setInCall(true);
    lc.poll();
    setInCall(false);
    lc.poll();
    setInCall(true);
    lc.poll();
    expect(onJoin).toHaveBeenCalledTimes(2);
    expect(lc.state).toBe("in-call");
  });
});

describe("rosterFingerprint", () => {
  it("is order-insensitive and change-sensitive", () => {
    const a = [
      { displayName: "Maria Silva", participantID: "pid-2", isSelf: false },
      { displayName: null, participantID: "pid-1", isSelf: true },
    ];
    const b = [a[1], a[0]];
    expect(C.rosterFingerprint(a)).toBe(C.rosterFingerprint(b));
    const c = [...a, { displayName: "João Pereira", isSelf: false }];
    expect(C.rosterFingerprint(c)).not.toBe(C.rosterFingerprint(a));
  });
});
