// Synthetic fixtures shared by the provisioning script and integration tests.
// No deployment identity or credential belongs in this module.
export type ReviewFixtureIds = { oats: string; soup: string; log: string; estimate: string; daily: string };
export function reviewFixtureIds(): ReviewFixtureIds {
  return { oats: crypto.randomUUID(), soup: crypto.randomUUID(), log: crypto.randomUUID(),
    estimate: crypto.randomUUID(), daily: crypto.randomUUID() };
}
export function reviewSeed(tenantId: string, codeHash: string, expiresAt: string,
  ids: ReviewFixtureIds, now = new Date(), reset = false): string {
  const q = (v: string) => `'${v.replaceAll("'", "''")}'`;
  const time = q(now.toISOString());
  const day = new Date(now.getTime() - 86400000).toISOString().slice(0, 10);
  const tenant = q(tenantId);
  const health = Array.from({ length: 7 }, (_, i) => ({
    localDate: new Date(Date.parse(day) - (6 - i) * 86400000).toISOString().slice(0, 10),
    restingKcal: 1600, activeKcal: 400, waterMl: i === 6 ? 2250 : 1750,
    weightKg: 75, bodyFatPercent: null,
  }));
  const sql = [
    `INSERT OR IGNORE INTO tenants (id, apple_subject, email, created_at, updated_at) VALUES (${tenant}, ${q(`review:${tenantId}`)}, NULL, ${time}, ${time});`,
    `INSERT OR IGNORE INTO review_credentials (token_hash, tenant_id, expires_at) VALUES (${q(codeHash)}, ${tenant}, ${q(expiresAt)});`,
    `INSERT OR IGNORE INTO profiles (tenant_id, height_cm, weight_kg, estimate_profile, deficit_kcal, deficit_percent, updated_at) VALUES (${tenant}, 175, 75, 'neutral', 450, 15, ${time});`,
    `INSERT OR IGNORE INTO foods (id, tenant_id, name, serving, kcal, fruit_veg_portions, source, created_at, updated_at) VALUES (${q(ids.oats)}, ${tenant}, 'Banana oats', 'one bowl', 350, 1, 'seed', ${time}, ${time});`,
    `INSERT OR IGNORE INTO foods (id, tenant_id, name, serving, kcal, fruit_veg_portions, source, created_at, updated_at) VALUES (${q(ids.soup)}, ${tenant}, 'Vegetable soup', 'one bowl', 180, 1, 'seed', ${time}, ${time});`,
    `INSERT OR IGNORE INTO food_logs (id, tenant_id, food_id, food_name, serving, quantity, kcal, fruit_veg_portions, local_date, logged_at) VALUES (${q(ids.log)}, ${tenant}, ${q(ids.soup)}, 'Vegetable soup', 'one bowl', 1, 180, 1, ${q(day)}, ${time});`,
    `INSERT OR IGNORE INTO pending_estimations (id, tenant_id, description, state, local_date, created_at, updated_at) VALUES (${q(ids.estimate)}, ${tenant}, 'Greek yogurt with a banana and 30 g oats', 'pending', ${q(day)}, ${time}, ${time});`,
    `INSERT OR IGNORE INTO daily_feedback_requests (id, tenant_id, local_date, time_zone, health_json, state, created_at, updated_at) VALUES (${q(ids.daily)}, ${tenant}, ${q(day)}, 'Europe/Lisbon', ${q(JSON.stringify(health))}, 'pending', ${time}, ${time});`,
  ];
  if (reset) sql.push(
    `UPDATE foods SET fruit_veg_portions = 1 WHERE id = ${q(ids.soup)} AND tenant_id = ${tenant};`,
    `UPDATE food_logs SET fruit_veg_portions = 1 WHERE id = ${q(ids.log)} AND tenant_id = ${tenant};`,
    `UPDATE pending_estimations SET state = 'pending', proposed_name = NULL, proposed_serving = NULL, proposed_kcal = NULL, proposed_fruit_veg_portions = NULL, agent_note = NULL, agent_reasoning = NULL, local_date = ${q(day)}, updated_at = ${time} WHERE id = ${q(ids.estimate)} AND tenant_id = ${tenant};`,
    `UPDATE daily_feedback_requests SET state = 'pending', feedback_text = NULL, health_json = ${q(JSON.stringify(health))}, updated_at = ${time} WHERE id = ${q(ids.daily)} AND tenant_id = ${tenant};`,
  );
  return sql.join("\n");
}
