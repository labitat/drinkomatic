CREATE TABLE users (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	name VARCHAR(60),
	hash VARCHAR(40) UNIQUE,
	balance FLOAT
);
INSERT INTO users SELECT id, member, hash, balance FROM accounts;
DROP TABLE accounts;

CREATE TABLE log (
	dt VARCHAR(23),
	uid INTEGER,
	pid INTEGER,
	count INTEGER,
	price FLOAT
);
INSERT INTO log SELECT dt, account_id, product_id, 1, amount FROM purchases;
DROP TABLE purchases;
