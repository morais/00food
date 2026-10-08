import { describe, expect, it } from "vitest";
import { migratedD1 } from "./d1";

describe("expired auth data sweep", () => {
  it("finds revoked credentials through an index instead of scanning", () => {
    const { db } = migratedD1();
    try {
      const plan = db.prepare("EXPLAIN QUERY PLAN DELETE FROM credentials WHERE revoked_at IS NOT NULL").all() as
        { detail: string }[];
      expect(plan.map(step => step.detail).join(" ")).toContain("credentials_revoked");
    } finally { db.close(); }
  });
});
