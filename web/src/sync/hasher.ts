import SparkMD5 from 'spark-md5';

export const PARTIAL_MD5_OFFSETS = [
  0,
  1024,
  4096,
  16384,
  65536,
  262144,
  1048576,
  4194304,
  16777216,
  67108864,
  268435456,
  1073741824,
] as const;

export function partialMd5Bytes(bytes: Uint8Array): string {
  const spark = new SparkMD5.ArrayBuffer();
  for (const offset of PARTIAL_MD5_OFFSETS) {
    if (offset >= bytes.byteLength) break;
    const end = Math.min(offset + 1024, bytes.byteLength);
    spark.append(bytes.slice(offset, end).buffer);
  }
  return spark.end();
}

export async function partialMd5Blob(blob: Blob): Promise<string> {
  const spark = new SparkMD5.ArrayBuffer();
  for (const offset of PARTIAL_MD5_OFFSETS) {
    if (offset >= blob.size) break;
    const chunk = await blob.slice(offset, Math.min(offset + 1024, blob.size)).arrayBuffer();
    if (chunk.byteLength === 0) break;
    spark.append(chunk);
  }
  return spark.end();
}

export async function sha256Hex(data: Uint8Array | string): Promise<string> {
  const buf = typeof data === 'string' ? new TextEncoder().encode(data) : data.slice();
  const hashBuf = await crypto.subtle.digest('SHA-256', buf.buffer);
  return Array.from(new Uint8Array(hashBuf))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

export async function annotationId(bookId: string, text: string, anchor = ''): Promise<string> {
  const normText = (text || '').trim().replace(/\s+/g, ' ');
  const digest = await sha256Hex(`${bookId}|${normText}|${anchor}`);
  return `ann_${digest.slice(0, 10)}`;
}

export function generateBookId(): string {
  const arr = new Uint8Array(4);
  crypto.getRandomValues(arr);
  return Array.from(arr)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}
