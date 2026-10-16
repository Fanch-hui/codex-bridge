CREATE TABLE relay_requests (
  id TEXT PRIMARY KEY,
  generation TEXT NOT NULL,
  method TEXT NOT NULL,
  headers TEXT NOT NULL,
  body TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending',
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  response_status INTEGER,
  response_headers TEXT,
  completion_id TEXT
);
--> statement-breakpoint
CREATE INDEX relay_pending ON relay_requests(generation, state, created_at);
--> statement-breakpoint
CREATE INDEX relay_expiry ON relay_requests(expires_at);
--> statement-breakpoint
CREATE TABLE relay_response_parts (
  request_id TEXT NOT NULL,
  part INTEGER NOT NULL,
  body TEXT NOT NULL,
  PRIMARY KEY (request_id, part)
);
