CREATE TABLE recording_store_metadata (
      singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
      owner_scope TEXT NOT NULL,
      sdk_user_id TEXT,
      canonical_user_id TEXT
    );
CREATE TABLE recordings (
      recording_id TEXT PRIMARY KEY NOT NULL,
      owner_scope TEXT NOT NULL,
      sdk_user_id TEXT,
      canonical_user_id TEXT,
      activity_session_id TEXT NOT NULL,
      activity_key TEXT NOT NULL,
      session_started_at TEXT NOT NULL,
      recording_started_at TEXT NOT NULL,
      ended_at TEXT,
      device_identity TEXT,
      phase TEXT NOT NULL CHECK(phase IN ('active','finalizing','finished')),
      input_state TEXT NOT NULL,
      recovery_state TEXT NOT NULL,
      route_quality TEXT NOT NULL,
      issues TEXT NOT NULL,
      point_count INTEGER NOT NULL CHECK(point_count >= 0),
      segment_count INTEGER NOT NULL CHECK(segment_count >= 0),
      unresolved_gap_count INTEGER NOT NULL CHECK(unresolved_gap_count >= 0),
      first_sample_at TEXT,
      last_sample_at TEXT,
      distance_meters REAL,
      route_revision INTEGER NOT NULL CHECK(route_revision >= 0),
      previous_route_revision INTEGER NOT NULL CHECK(previous_route_revision >= 0),
      route_changed_from TEXT,
      UNIQUE(owner_scope, activity_session_id)
    );
CREATE UNIQUE INDEX recording_one_active
      ON recordings(owner_scope) WHERE phase IN ('active','finalizing');
CREATE TABLE route_points (
      recording_id TEXT NOT NULL REFERENCES recordings(recording_id) ON DELETE CASCADE,
      sample_key TEXT NOT NULL,
      sampled_at TEXT NOT NULL,
      latitude REAL NOT NULL,
      longitude REAL NOT NULL,
      altitude_meters REAL,
      delivery TEXT NOT NULL,
      segment_id TEXT NOT NULL,
      PRIMARY KEY(recording_id, sample_key)
    );
CREATE INDEX route_points_time
      ON route_points(recording_id, sampled_at, sample_key);
CREATE TABLE route_gaps (
      gap_id TEXT PRIMARY KEY NOT NULL,
      recording_id TEXT NOT NULL REFERENCES recordings(recording_id) ON DELETE CASCADE,
      from_time TEXT NOT NULL,
      until_time TEXT,
      reason TEXT NOT NULL,
      state TEXT NOT NULL
    );
ALTER TABLE recordings ADD COLUMN distance_edge_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE route_points ADD COLUMN device_identity TEXT;
ALTER TABLE route_points ADD COLUMN sample_order INTEGER;
ALTER TABLE route_points ADD COLUMN previous_key TEXT;
ALTER TABLE route_points ADD COLUMN edge_distance REAL;
ALTER TABLE route_gaps ADD COLUMN from_order INTEGER;
ALTER TABLE route_gaps ADD COLUMN until_order INTEGER;
DROP INDEX route_points_time;
CREATE INDEX route_points_time ON route_points(recording_id, sample_order, sample_key);
CREATE INDEX route_gaps_time ON route_gaps(recording_id, from_order, gap_id);

CREATE TABLE recording_recovery (
  recording_id TEXT PRIMARY KEY NOT NULL REFERENCES recordings(recording_id) ON DELETE CASCADE,
  processed_through INTEGER,
  needed INTEGER NOT NULL DEFAULT 0 CHECK(needed IN (0,1))
);
