const retentionMs = 320_000;
const responseChunkLength = 512 * 1024;

export async function relayGeneration(mcpKey, relayKey) {
  const input = new TextEncoder().encode(`codex-bridge-sites-generation-v1\n${mcpKey}\n${relayKey}`);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", input));
  return Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
}

export class RelayQueue {
  constructor(db, generation) { this.db = db; this.generation = generation; }

  async cleanup(now = Date.now()) {
    await this.db.batch([
      this.db.prepare(`DELETE FROM relay_response_parts WHERE request_id IN
        (SELECT id FROM relay_requests WHERE expires_at <= ?)`).bind(now),
      this.db.prepare("DELETE FROM relay_requests WHERE expires_at <= ?").bind(now),
    ]);
  }

  async enqueue(request, now = Date.now()) {
    await this.cleanup(now);
    const id = crypto.randomUUID();
    const result = await this.db.prepare(`INSERT INTO relay_requests
      (id, generation, method, headers, body, created_at, expires_at)
      SELECT ?, ?, ?, ?, ?, ?, ? WHERE
      (SELECT COUNT(*) FROM relay_requests WHERE generation = ? AND state != 'delivered') < 16`)
      .bind(id, this.generation, request.method, JSON.stringify(request.headers), request.body,
        now, now + retentionMs, this.generation).run();
    return result.meta.changes === 1 ? id : null;
  }

  async claim(limit, now = Date.now()) {
    await this.cleanup(now);
    const result = await this.db.prepare(`UPDATE relay_requests SET state = 'claimed'
      WHERE id IN (SELECT id FROM relay_requests WHERE generation = ? AND state = 'pending'
        AND expires_at > ? ORDER BY created_at, id LIMIT ?)
      AND state = 'pending' RETURNING id, method, headers, body`)
      .bind(this.generation, now, limit).all();
    return result.results.map(row => ({
      id: row.id, method: row.method, headers: JSON.parse(row.headers), body: row.body,
    }));
  }

  async complete(result, now = Date.now()) {
    const row = await this.db.prepare("SELECT state FROM relay_requests WHERE id = ? AND generation = ? AND expires_at > ?")
      .bind(result.id, this.generation, now).first();
    if (!row) return false;
    if (row.state === "completed" || row.state === "delivered") return true;
    if (row.state !== "claimed") return false;
    const completionId = crypto.randomUUID();
    const statements = [this.db.prepare(`UPDATE relay_requests
      SET state = 'completed', response_status = ?, response_headers = ?, body = '', completion_id = ?
      WHERE id = ? AND generation = ? AND state = 'claimed' AND expires_at > ?`)
      .bind(result.status, JSON.stringify(result.headers), completionId, result.id, this.generation, now)];
    for (let offset = 0, part = 0; offset < result.body.length; offset += responseChunkLength, part++) {
      statements.push(this.db.prepare(`INSERT OR IGNORE INTO relay_response_parts
        (request_id, part, body) SELECT ?, ?, ? WHERE EXISTS
        (SELECT 1 FROM relay_requests WHERE id = ? AND generation = ? AND state = 'completed' AND completion_id = ?)`)
        .bind(result.id, part, result.body.slice(offset, offset + responseChunkLength),
          result.id, this.generation, completionId));
    }
    await this.db.batch(statements);
    return true;
  }

  async response(id) {
    const row = await this.db.prepare(`SELECT response_status, response_headers
      FROM relay_requests WHERE id = ? AND generation = ? AND state = 'completed'`)
      .bind(id, this.generation).first();
    if (!row) return null;
    const parts = await this.db.prepare(`SELECT body FROM relay_response_parts
      WHERE request_id = ? ORDER BY part`).bind(id).all();
    await this.db.batch([
      this.db.prepare("UPDATE relay_requests SET state = 'delivered', headers = '{}' WHERE id = ?").bind(id),
      this.db.prepare("DELETE FROM relay_response_parts WHERE request_id = ?").bind(id),
    ]);
    return { status: row.response_status, headers: JSON.parse(row.response_headers),
      body: parts.results.map(part => part.body).join("") };
  }
}
