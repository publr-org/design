// Engine workers: the render workers (each holds its own engine session with the
// document, and draws one tile at a time) and the import worker. Calls are messages with
// an id, answered by the same id; a message carrying `note` instead is progress, passed
// to `onNote`.

export type Reply = { id: number; ok: boolean; error?: string; [key: string]: unknown };

export type Slot = {
  index: number;
  worker: Worker;
  /** Drawing a tile now. */
  busy: boolean;
  /** Holds the open document and may take tiles. */
  ready: boolean;
  /** Engine memory, bytes, as the last tile reported it. */
  memory: number;
  next: number;
  waiting: Map<number, { resolve: (r: Reply) => void; reject: (e: Error) => void }>;
};

export class Pool {
  slots: Slot[] = [];
  /** Progress a worker reports while it works on a call. */
  onNote: (note: string) => void = () => {};

  /** `count` workers running `script` (default: the render worker). */
  constructor(count: number, script: URL = new URL("./worker.js", import.meta.url)) {
    for (let i = 0; i < count; i++) {
      const worker = new Worker(script, { type: "module" });
      const slot: Slot = { index: i, worker, busy: false, ready: false, memory: 0, next: 1, waiting: new Map() };
      worker.onmessage = (event: MessageEvent) => {
        const reply = event.data as Reply;
        if (typeof reply.note === "string") {
          this.onNote(reply.note);
          return;
        }
        const cb = slot.waiting.get(reply.id);
        if (!cb) return;
        slot.waiting.delete(reply.id);
        if (reply.ok) cb.resolve(reply);
        else cb.reject(new Error(reply.error ?? "worker failed"));
      };
      worker.onerror = (event: ErrorEvent) => console.error("worker", i, event.message);
      this.slots.push(slot);
    }
  }

  call(slot: Slot, msg: Record<string, unknown>, transfer: Transferable[] = []): Promise<Reply> {
    const id = slot.next++;
    return new Promise((resolve, reject) => {
      slot.waiting.set(id, { resolve, reject });
      slot.worker.postMessage({ ...msg, id }, transfer);
    });
  }

  /** Stops every worker; calls still waiting fail. */
  terminate(): void {
    for (const slot of this.slots) {
      slot.worker.terminate();
      for (const cb of slot.waiting.values()) cb.reject(new Error("worker stopped"));
      slot.waiting.clear();
    }
  }

  /** Sends a message to every worker (each gets its own copy of the bytes). */
  all(msgFor: (slot: Slot) => Record<string, unknown>): Promise<Reply[]> {
    return Promise.all(this.slots.map((slot) => this.call(slot, msgFor(slot))));
  }
}
