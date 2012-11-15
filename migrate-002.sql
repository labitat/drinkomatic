CREATE TABLE tmp (
	dt VARCHAR(23),
	uid INTEGER,
	oid INTEGER,
	count INTEGER,
	amount FLOAT
);
INSERT INTO tmp SELECT dt, uid, pid, count, price FROM log;
DROP TABLE log;
ALTER TABLE tmp RENAME TO log;

UPDATE log SET count = NULL WHERE oid = 1;
UPDATE log SET oid = uid WHERE count IS NULL;
DELETE FROM products WHERE id = 1;

CREATE VIEW "full_log" AS SELECT
		dt, uid, oid,
		users.name AS uname,
		coalesce(object.name,products.name,'<deleted>') AS oname,
		count, amount
	FROM log
		LEFT JOIN users ON uid = users.id
		LEFT JOIN products ON count NOT NULL AND oid = products.id
		LEFT JOIN users AS object ON count IS NULL AND oid = object.id;
