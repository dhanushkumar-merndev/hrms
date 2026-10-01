// Deletion of one claimed cleanup batch. Only the exact inventoried object
// keys handed out by internal_cleanup_claim are removed — never a prefix or
// a listing. A key that is already gone counts as deleted: the inventory
// expected it and the acknowledged archive holds its verified bytes.

export interface CleanupItem {
  item_id: number;
  bucket: string;
  object_key: string;
}

export interface CleanupResult {
  item_id: number;
  ok: boolean;
  error?: string;
}

export type Remover = (bucket: string, keys: string[]) => Promise<{ error: { message?: string } | null }>;

export async function deleteBatch(items: CleanupItem[], remove: Remover, chunk = 20): Promise<CleanupResult[]> {
  const byBucket = new Map<string, CleanupItem[]>();
  for (const item of items) {
    if (!item.object_key || item.object_key.includes("..") || item.object_key.startsWith("/")) {
      continue; // never happens for server-generated keys; refuse rather than guess
    }
    byBucket.set(item.bucket, [...(byBucket.get(item.bucket) ?? []), item]);
  }
  const results: CleanupResult[] = [];
  for (const [bucket, group] of byBucket) {
    for (let i = 0; i < group.length; i += chunk) {
      const part = group.slice(i, i + chunk);
      let error: string | null = null;
      try {
        const res = await remove(bucket, part.map((p) => p.object_key));
        if (res.error) error = String(res.error.message ?? "Storage error").slice(0, 200);
      } catch (e) {
        error = String((e as Error)?.message ?? e).slice(0, 200);
      }
      for (const p of part) results.push(error ? { item_id: p.item_id, ok: false, error } : { item_id: p.item_id, ok: true });
    }
  }
  return results;
}
