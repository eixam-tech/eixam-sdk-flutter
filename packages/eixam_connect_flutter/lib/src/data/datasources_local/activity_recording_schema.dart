import 'package:sqflite/sqflite.dart';

import 'activity_recording_history_sql.dart';

/// Private schema. Version six adds local finished-recording soft deletion.
abstract final class ActivityRecordingSchema {
  static const version = 6;

  static Future<void> create(Database db, int version) async {
    await db.execute('''CREATE TABLE recording_store_metadata (
      singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
      owner_scope TEXT NOT NULL,
      sdk_user_id TEXT,
      canonical_user_id TEXT
    )''');
    await db.execute('''CREATE TABLE recordings (
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
    )''');
    await db.execute('''CREATE UNIQUE INDEX recording_one_active
      ON recordings(owner_scope) WHERE phase IN ('active','finalizing')''');
    await db.execute('''CREATE TABLE route_points (
      recording_id TEXT NOT NULL REFERENCES recordings(recording_id) ON DELETE CASCADE,
      sample_key TEXT NOT NULL,
      sampled_at TEXT NOT NULL,
      latitude REAL NOT NULL,
      longitude REAL NOT NULL,
      altitude_meters REAL,
      delivery TEXT NOT NULL,
      segment_id TEXT NOT NULL,
      PRIMARY KEY(recording_id, sample_key)
    )''');
    await db.execute('''CREATE INDEX route_points_time
      ON route_points(recording_id, sampled_at, sample_key)''');
    await db.execute('''CREATE TABLE route_gaps (
      gap_id TEXT PRIMARY KEY NOT NULL,
      recording_id TEXT NOT NULL REFERENCES recordings(recording_id) ON DELETE CASCADE,
      from_time TEXT NOT NULL,
      until_time TEXT,
      reason TEXT NOT NULL,
      state TEXT NOT NULL
    )''');
    await upgrade(db, 1, version);
  }

  static Future<void> upgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 1 || oldVersion > 5 || newVersion != 6) {
      throw StateError('Unsupported recording schema');
    }
    if (oldVersion == 1) {
      // Approved v1 has metadata only. Unexpected route artifacts are evidence,
      // not permission to reset or invent ownership/topology for those rows.
      final count = await db.rawQuery('''SELECT
      (SELECT COUNT(*) FROM route_points) +
      (SELECT COUNT(*) FROM route_gaps) AS n''');
      if (count.single['n'] != 0) {
        throw StateError('Unexpected legacy route data');
      }
      await db.execute(
        'ALTER TABLE recordings ADD COLUMN distance_edge_count INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'ALTER TABLE route_points ADD COLUMN device_identity TEXT',
      );
      await db.execute(
        'ALTER TABLE route_points ADD COLUMN sample_order INTEGER',
      );
      await db.execute('ALTER TABLE route_points ADD COLUMN previous_key TEXT');
      await db.execute(
        'ALTER TABLE route_points ADD COLUMN edge_distance REAL',
      );
      await db.execute('ALTER TABLE route_gaps ADD COLUMN from_order INTEGER');
      await db.execute('ALTER TABLE route_gaps ADD COLUMN until_order INTEGER');
      await db.execute('DROP INDEX route_points_time');
      await db.execute(
        'CREATE INDEX route_points_time ON route_points(recording_id, sample_order, sample_key)',
      );
      await db.execute(
        'CREATE INDEX route_gaps_time ON route_gaps(recording_id, from_order, gap_id)',
      );
    }
    if (oldVersion < 3) {
      await db.execute('''CREATE TABLE recording_recovery (
      recording_id TEXT PRIMARY KEY NOT NULL REFERENCES recordings(recording_id) ON DELETE CASCADE,
      processed_through INTEGER,
      needed INTEGER NOT NULL DEFAULT 0 CHECK(needed IN (0,1))
    )''');
      await db.execute(
        '''INSERT INTO recording_recovery(recording_id, needed)
      SELECT recording_id, CASE WHEN unresolved_gap_count > 0 THEN 1 ELSE 0 END FROM recordings''',
      );
    }
    if (oldVersion < 4) {
      await db.execute(
        'ALTER TABLE recordings ADD COLUMN finalization_started_at TEXT',
      );
      await db.execute(
        'ALTER TABLE recordings ADD COLUMN finalization_deadline_at TEXT',
      );
    }
    if (oldVersion < 5) await ActivityRecordingHistorySql.create(db);
    await db.execute(
      'ALTER TABLE recordings ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0',
    );
  }
}
