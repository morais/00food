CREATE TABLE tenants (
  id TEXT PRIMARY KEY,
  apple_subject TEXT NOT NULL UNIQUE,
  email TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE credentials (
  token_hash TEXT PRIMARY KEY,
  id TEXT NOT NULL UNIQUE,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('app', 'mcp')),
  audience TEXT NOT NULL,
  scopes TEXT NOT NULL,
  label TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  last_used_at TEXT
);
CREATE INDEX credentials_tenant ON credentials(tenant_id, kind, created_at);
CREATE INDEX credentials_expires ON credentials(expires_at);

CREATE TABLE oauth_flows (
  id_hash TEXT PRIMARY KEY,
  client_id TEXT NOT NULL,
  client_name TEXT NOT NULL,
  redirect_uri TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  client_state TEXT,
  resource TEXT NOT NULL,
  scopes TEXT NOT NULL,
  apple_nonce TEXT NOT NULL,
  tenant_id TEXT REFERENCES tenants(id) ON DELETE CASCADE,
  consent_hash TEXT,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE INDEX oauth_flows_expires ON oauth_flows(expires_at);

CREATE TABLE oauth_codes (
  code_hash TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  client_id TEXT NOT NULL,
  redirect_uri TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  resource TEXT NOT NULL,
  scopes TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  redeemed_at TEXT
);
CREATE INDEX oauth_codes_expires ON oauth_codes(expires_at);

CREATE TABLE review_credentials (
  token_hash TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  expires_at TEXT NOT NULL,
  revoked_at TEXT
);

CREATE TABLE profiles (
  tenant_id TEXT PRIMARY KEY REFERENCES tenants(id) ON DELETE CASCADE,
  height_cm REAL NOT NULL CHECK (height_cm BETWEEN 100 AND 250),
  weight_kg REAL NOT NULL CHECK (weight_kg BETWEEN 25 AND 400),
  estimate_profile TEXT NOT NULL CHECK (estimate_profile IN ('female', 'male', 'neutral')),
  deficit_kcal INTEGER NOT NULL CHECK (deficit_kcal BETWEEN 0 AND 1000),
  updated_at TEXT NOT NULL
);

CREATE TABLE foods (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  serving TEXT NOT NULL,
  kcal INTEGER NOT NULL CHECK (kcal BETWEEN 1 AND 5000),
  source TEXT NOT NULL CHECK (source IN ('manual', 'seed', 'agent')),
  use_count INTEGER NOT NULL DEFAULT 0,
  last_used_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX foods_recent ON foods(tenant_id, use_count DESC, last_used_at DESC);
CREATE INDEX foods_name ON foods(tenant_id, name COLLATE NOCASE);

CREATE TABLE food_logs (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  food_id TEXT NOT NULL REFERENCES foods(id) ON DELETE CASCADE,
  food_name TEXT NOT NULL,
  serving TEXT NOT NULL,
  quantity REAL NOT NULL CHECK (quantity > 0 AND quantity <= 20),
  kcal INTEGER NOT NULL CHECK (kcal BETWEEN 1 AND 50000),
  local_date TEXT NOT NULL,
  logged_at TEXT NOT NULL
);
CREATE INDEX food_logs_day ON food_logs(tenant_id, local_date DESC, logged_at DESC);

CREATE TABLE pending_estimations (
  id TEXT PRIMARY KEY,
  tenant_id TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  description TEXT NOT NULL,
  photo_key TEXT,
  state TEXT NOT NULL CHECK (state IN ('pending', 'proposed')),
  proposed_name TEXT,
  proposed_serving TEXT,
  proposed_kcal INTEGER,
  agent_note TEXT,
  local_date TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX pending_estimations_recent ON pending_estimations(tenant_id, state, created_at DESC);
