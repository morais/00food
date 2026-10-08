import { describe, expect, it } from "vitest";
import { routeApi, type Env } from "../src/api";
import type { Principal } from "../src/auth";
import { migratedD1 } from "./d1";

const principal: Principal = { tenantId: "tenant", kind: "app", scopes: [], tokenHash: "hash" };
const jpeg = new Uint8Array([0xff, 0xd8, 0x01, 0x02, 0xff, 0xd9]);
const id = "6f1c2a4e-8d3b-4c5a-9e7f-0a1b2c3d4e5f";

function setup() {
  const { db, d1 } = migratedD1();
  const now = "2026-10-08T00:00:00Z";
  db.prepare("INSERT INTO tenants (id, apple_subject, email, created_at, updated_at) VALUES ('tenant', 'a', NULL, ?, ?)").run(now, now);
  const stored = new Map<string, Uint8Array>();
  const photos = { async put(key: string, value: Uint8Array) { stored.set(key, new Uint8Array(value)); } } as unknown as R2Bucket;
  return { db, stored, env: { DB: d1, PHOTOS: photos, PUBLIC_ORIGIN: "https://api.00food.com" } as Env };
}

async function multipart(form: FormData): Promise<Request> {
  // Build the body first so the request carries a Content-Length, as URLSession does.
  const encoded = new Request("https://x", { method: "POST", body: form });
  const bytes = new Uint8Array(await encoded.arrayBuffer());
  return new Request("https://api.00food.com/v1/estimations", { method: "POST", body: bytes,
    headers: { "content-type": encoded.headers.get("content-type")!, "content-length": String(bytes.length) } });
}

describe("estimate creation with a photo", () => {
  it("stores a multipart photo and description together in one request", async () => {
    const { db, stored, env } = setup();
    try {
      const form = new FormData();
      form.set("id", id);
      form.set("description", "Lentil soup, one bowl");
      form.set("localDate", "2026-10-08");
      form.set("photo", new Blob([jpeg], { type: "image/jpeg" }), "photo.jpg");
      const response = await routeApi(await multipart(form), env, principal);
      expect(response.status).toBe(201);
      expect(await response.json()).toMatchObject({ estimation: { id, description: "Lentil soup, one bowl", hasPhoto: true } });
      expect([...stored.get(`tenant/${id}.jpg`)!]).toEqual([...jpeg]);
      expect(db.prepare("SELECT COUNT(*) AS n FROM food_events").get()).toEqual({ n: 1 });
    } finally { db.close(); }
  });

  it("accepts a multipart estimate without a photo", async () => {
    const { db, env } = setup();
    try {
      const form = new FormData();
      form.set("description", "Toast");
      form.set("localDate", "2026-10-08");
      const response = await routeApi(await multipart(form), env, principal);
      expect(response.status).toBe(201);
      expect(await response.json()).toMatchObject({ estimation: { hasPhoto: false } });
    } finally { db.close(); }
  });

  it("refuses an oversized multipart body before parsing and a non-JPEG part", async () => {
    const { db, env } = setup();
    try {
      const big = new Request("https://api.00food.com/v1/estimations", { method: "POST", body: "x",
        headers: { "content-type": "multipart/form-data; boundary=b", "content-length": "5000000" } });
      expect((await routeApi(big, env, principal)).status).toBe(413);
      const form = new FormData();
      form.set("localDate", "2026-10-08");
      form.set("photo", new Blob([new Uint8Array([1, 2, 3])]), "photo.jpg");
      expect((await routeApi(await multipart(form), env, principal)).status).toBe(415);
    } finally { db.close(); }
  });

  it("still accepts the JSON base64 form from older app builds", async () => {
    const { db, stored, env } = setup();
    try {
      const response = await routeApi(new Request("https://api.00food.com/v1/estimations", { method: "POST",
        body: JSON.stringify({ id, description: "Soup", localDate: "2026-10-08", photoBase64: btoa(String.fromCharCode(...jpeg)) }) }),
      env, principal);
      expect(response.status).toBe(201);
      expect(stored.has(`tenant/${id}.jpg`)).toBe(true);
    } finally { db.close(); }
  });
});
