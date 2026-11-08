declare namespace Cloudflare {
  interface Env {
    DB?: D1Database;
    BUCKET?: R2Bucket;
    MESSAGE_CENTER_ADMIN_EMAIL?: string;
    MESSAGE_CENTER_ATTACHMENT_LIMIT_BYTES?: string;
  }
}
