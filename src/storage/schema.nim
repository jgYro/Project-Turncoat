import driver

const SchemaVersion* = 4

proc initializeSchema*(db: Connection) =
  db.execute("PRAGMA foreign_keys = ON")
  db.execute("PRAGMA busy_timeout = 5000")
  db.execute("PRAGMA journal_mode = WAL")
  if db.scalarInt("PRAGMA foreign_keys") != 1:
    raise newException(StorageError, "SQLite foreign keys are required")
  let version = db.scalarInt("PRAGMA user_version")
  if version > SchemaVersion:
    raise newException(StorageError, "Database schema is newer than this application")
  if version == 0:
    db.transaction:
      db.execute("""CREATE TABLE datasets (
        id TEXT PRIMARY KEY NOT NULL,
        CHECK(length(id) BETWEEN 1 AND 64 AND id NOT GLOB '*[^a-zA-Z0-9_-]*'))""")
      db.execute("""CREATE TABLE nodes (
        oid TEXT PRIMARY KEY NOT NULL,
        dataset TEXT NOT NULL REFERENCES datasets(id),
        label TEXT NOT NULL CHECK(length(label) BETWEEN 1 AND 128),
        properties TEXT NOT NULL CHECK(json_valid(properties) AND json_type(properties) = 'object'),
        search_text TEXT NOT NULL,
        UNIQUE(dataset, oid))""")
      db.execute("""CREATE TABLE edges (
        oid TEXT PRIMARY KEY NOT NULL,
        dataset TEXT NOT NULL REFERENCES datasets(id),
        source TEXT NOT NULL, target TEXT NOT NULL,
        label TEXT NOT NULL CHECK(length(label) BETWEEN 1 AND 128),
        properties TEXT NOT NULL CHECK(json_valid(properties) AND json_type(properties) = 'object'),
        FOREIGN KEY(dataset, source) REFERENCES nodes(dataset, oid) ON DELETE CASCADE,
        FOREIGN KEY(dataset, target) REFERENCES nodes(dataset, oid) ON DELETE CASCADE)""")
      for statement in [
        "CREATE INDEX nodes_label ON nodes(label)",
        "CREATE INDEX nodes_dataset_label ON nodes(dataset, label, oid)",
        "CREATE INDEX edges_source ON edges(source)",
        "CREATE INDEX edges_target ON edges(target)",
        "CREATE INDEX edges_label ON edges(label)",
        "CREATE INDEX edges_dataset_oid ON edges(dataset, oid)",
        "CREATE INDEX edges_dataset_source ON edges(dataset, source, oid)",
        "CREATE INDEX edges_dataset_target ON edges(dataset, target, oid)",
        "CREATE INDEX edges_dataset_label ON edges(dataset, label, oid)"]:
        db.execute(statement)
      db.execute("""CREATE TRIGGER nodes_identity BEFORE INSERT ON nodes BEGIN
        SELECT RAISE(ABORT, 'OID already belongs to an edge') WHERE EXISTS (SELECT 1 FROM edges WHERE oid=new.oid);
        SELECT RAISE(ABORT, 'OID belongs to a different dataset') WHERE EXISTS
          (SELECT 1 FROM nodes WHERE oid=new.oid AND dataset<>new.dataset);
      END""")
      db.execute("""CREATE TRIGGER edges_identity BEFORE INSERT ON edges BEGIN
        SELECT RAISE(ABORT, 'OID already belongs to a node') WHERE EXISTS (SELECT 1 FROM nodes WHERE oid=new.oid);
        SELECT RAISE(ABORT, 'OID belongs to a different dataset') WHERE EXISTS
          (SELECT 1 FROM edges WHERE oid=new.oid AND dataset<>new.dataset);
      END""")
      db.execute("""CREATE TRIGGER nodes_identity_immutable BEFORE UPDATE OF oid,dataset ON nodes
        WHEN old.oid<>new.oid OR old.dataset<>new.dataset BEGIN
        SELECT RAISE(ABORT, 'Record identity is immutable'); END""")
      db.execute("""CREATE TRIGGER edges_identity_immutable BEFORE UPDATE OF oid,dataset ON edges
        WHEN old.oid<>new.oid OR old.dataset<>new.dataset BEGIN
        SELECT RAISE(ABORT, 'Record identity is immutable'); END""")
      db.execute("PRAGMA user_version = 1")
  if version < 2:
    db.transaction:
      db.execute("""CREATE TABLE analysis_reports (
        id TEXT PRIMARY KEY NOT NULL,
        dataset TEXT NOT NULL,
        node TEXT NOT NULL,
        kind TEXT NOT NULL CHECK(kind IN ('keywords','ai')),
        created_at TEXT NOT NULL,
        report TEXT NOT NULL CHECK(json_valid(report) AND json_type(report)='object'),
        FOREIGN KEY(dataset,node) REFERENCES nodes(dataset,oid) ON DELETE CASCADE)""")
      db.execute("CREATE INDEX analysis_reports_node ON analysis_reports(dataset,node,created_at DESC)")
      db.execute("PRAGMA user_version = 2")
  if version < 3:
    db.transaction:
      db.execute("""CREATE TABLE investigation_shares (
        token TEXT PRIMARY KEY NOT NULL,
        dataset TEXT NOT NULL REFERENCES datasets(id) ON DELETE CASCADE,
        created_at TEXT NOT NULL,
        snapshot TEXT NOT NULL CHECK(json_valid(snapshot) AND json_type(snapshot)='object'))""")
      db.execute("CREATE INDEX investigation_shares_dataset ON investigation_shares(dataset,created_at DESC)")
      db.execute("PRAGMA user_version = 3")
  if version < 4:
    db.transaction:
      db.execute("""CREATE TABLE analysis_jobs (
        id TEXT PRIMARY KEY NOT NULL,
        dataset TEXT NOT NULL, node TEXT NOT NULL,
        kind TEXT NOT NULL CHECK(kind IN ('keywords','ai')),
        state TEXT NOT NULL,
        dedupe_key TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        job TEXT NOT NULL CHECK(json_valid(job) AND json_type(job)='object'),
        FOREIGN KEY(dataset,node) REFERENCES nodes(dataset,oid) ON DELETE CASCADE)""")
      db.execute("CREATE INDEX analysis_jobs_state ON analysis_jobs(state,created_at)")
      db.execute("CREATE INDEX analysis_jobs_document ON analysis_jobs(dataset,node,created_at DESC)")
      db.execute("PRAGMA user_version = 4")
