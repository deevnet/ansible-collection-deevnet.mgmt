-- The VerneMQ auth database (ADR-0012 §8).
--
-- vmq_auth_acl and the insert form are VerneMQ's, quoted from the plugin's own
-- source at 2.2.0: apps/vmq_diversity/priv/auth/postgres_cockroach_commons.lua,
-- which documents the schema its queries require. Do not "improve" the column
-- names or types - the plugin's SQL is compiled in.
--
-- pgcrypto is required for the crypt()/gen_salt('bf') server-side hashing the
-- broker is configured to use.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS vmq_auth_acl
(
  mountpoint character varying(10) NOT NULL,
  client_id character varying(128) NOT NULL,
  username character varying(128) NOT NULL,
  password character varying(128),
  publish_acl json,
  subscribe_acl json,
  CONSTRAINT vmq_auth_acl_primary_key PRIMARY KEY (mountpoint, client_id, username)
);
