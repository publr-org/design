// A zip archive written in the browser: a `.pubd` file to download. Every entry is
// deflated (the importers read deflated entries); names are UTF-8. No zip64: an archive
// past 4 GB is refused.

const CRC = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(data: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < data.length; i++) c = CRC[(c ^ data[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

async function deflate(data: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([data]).stream().pipeThrough(new CompressionStream("deflate-raw"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

const encoder = new TextEncoder();
// 1980-01-01, the first date a zip can hold.
const DOS_DATE = 0x21;

type Written = { name: Uint8Array; crc: number; size: number; packed: number; offset: number };

/** Entries added one at a time, each deflated as it comes; `blob` ends the archive. */
export class ZipWriter {
  private parts: BlobPart[] = [];
  private written: Written[] = [];
  private offset = 0;

  async add(path: string, data: Uint8Array): Promise<void> {
    const name = encoder.encode(path);
    const packed = await deflate(data);
    const w: Written = { name, crc: crc32(data), size: data.length, packed: packed.length, offset: this.offset };
    if (w.offset + 30 + name.length + packed.length > 0xffffffff || data.length > 0xffffffff) throw new Error("the file is over 4 GB");
    const head = new DataView(new ArrayBuffer(30));
    head.setUint32(0, 0x04034b50, true);
    head.setUint16(4, 20, true);
    head.setUint16(6, 0x0800, true);
    head.setUint16(8, 8, true);
    head.setUint16(10, 0, true);
    head.setUint16(12, DOS_DATE, true);
    head.setUint32(14, w.crc, true);
    head.setUint32(18, w.packed, true);
    head.setUint32(22, w.size, true);
    head.setUint16(26, name.length, true);
    head.setUint16(28, 0, true);
    this.parts.push(head.buffer, name, packed);
    this.offset += 30 + name.length + packed.length;
    this.written.push(w);
  }

  blob(): Blob {
    const start = this.offset;
    let size = 0;
    for (const w of this.written) {
      const c = new DataView(new ArrayBuffer(46));
      c.setUint32(0, 0x02014b50, true);
      c.setUint16(4, 20, true);
      c.setUint16(6, 20, true);
      c.setUint16(8, 0x0800, true);
      c.setUint16(10, 8, true);
      c.setUint16(12, 0, true);
      c.setUint16(14, DOS_DATE, true);
      c.setUint32(16, w.crc, true);
      c.setUint32(20, w.packed, true);
      c.setUint32(24, w.size, true);
      c.setUint16(28, w.name.length, true);
      c.setUint32(42, w.offset, true);
      this.parts.push(c.buffer, w.name);
      size += 46 + w.name.length;
    }
    if (this.written.length > 0xffff || start + size > 0xffffffff) throw new Error("the file has too many entries");
    const end = new DataView(new ArrayBuffer(22));
    end.setUint32(0, 0x06054b50, true);
    end.setUint16(8, this.written.length, true);
    end.setUint16(10, this.written.length, true);
    end.setUint32(12, size, true);
    end.setUint32(16, start, true);
    this.parts.push(end.buffer);
    return new Blob(this.parts, { type: "application/zip" });
  }
}
