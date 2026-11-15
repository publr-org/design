// Undo and redo for Content mode: every change is a field's value before and after (its
// inner HTML, or some of its attributes), with the selection as it was before and after,
// so undo puts the selection back too. Typing in one field coalesces into steps; when the
// text edit ends, its steps become one (as in Design mode: Cmd+Z inside a text edit undoes
// the typing step by step, after it the whole edit at once).

/** The selection to put back: what is selected, the field being edited and its caret. */
export type Snap = { selection: string[]; editing: string; caret: [number, number] | null };

export type Value = { html: string } | { attrs: Record<string, string | null> };

export type Step = {
  key: string;
  before: Value;
  after: Value;
  selBefore: Snap;
  selAfter: Snap;
  /** The text edit it was made in (0: none). */
  session: number;
  /** What kind of typing, for coalescing ("insert", "delete", "" never coalesces). */
  kind: string;
  time: number;
};

export class History {
  undo: Step[] = [];
  redo: Step[] = [];

  push(step: Step): void {
    this.redo = [];
    const last = this.undo[this.undo.length - 1];
    if (last && step.kind && last.kind === step.kind && last.key === step.key && last.session === step.session && step.time - last.time < 1000) {
      last.after = step.after;
      last.selAfter = step.selAfter;
      last.time = step.time;
      return;
    }
    this.undo.push(step);
  }

  /** A text edit ended: its steps become one, undone with the field selected. */
  close(session: number, snap: Snap): void {
    let i = this.undo.length;
    while (i > 0 && this.undo[i - 1].session === session) i--;
    const steps = this.undo.slice(i);
    if (!steps.length) return;
    this.undo.length = i;
    this.undo.push({ ...steps[0], after: steps[steps.length - 1].after, selBefore: snap, selAfter: snap, session: 0, kind: "", time: 0 });
    this.redo = this.redo.filter((s) => s.session !== session);
  }
}
