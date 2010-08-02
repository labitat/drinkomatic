create table accounts (id integer primary key autoincrement, hash varchar(40) unique, member varchar(60), balance float);
create table products (id integer primary key autoincrement, barcode varchar(40) unique, price float, name varchar(255));

