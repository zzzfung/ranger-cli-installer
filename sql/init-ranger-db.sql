DROP DATABASE IF EXISTS ranger;
CREATE DATABASE IF NOT EXISTS ranger;

DROP USER IF EXISTS 'ranger'@'%';
CREATE USER IF NOT EXISTS 'ranger'@'%' IDENTIFIED BY '@MYSQL_RANGER_DB_USER_PASSWORD@';
GRANT ALL PRIVILEGES ON ranger.* TO 'ranger'@'%' WITH GRANT OPTION;