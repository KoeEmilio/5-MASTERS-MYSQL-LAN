-- ============================================================
--  Nodo 6 — Solo usuarios de sistema
--  La BD y tablas llegarán vía replicación desde el Nodo 1.
--  sql_log_bin=0 evita que estas sentencias generen GTIDs.
-- ============================================================
SET sql_log_bin = 0;

CREATE USER IF NOT EXISTS 'replicator'@'%' IDENTIFIED BY 'replpassword';
GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'%';

CREATE USER IF NOT EXISTS 'admin_lan'@'%' IDENTIFIED BY 'admin_secure_pass';
GRANT ALL PRIVILEGES ON *.* TO 'admin_lan'@'%' WITH GRANT OPTION;

FLUSH PRIVILEGES;
SET sql_log_bin = 1;
