# PostgresSQl


## ENV

Any config env can be set in the [postgres.env](./.config/postgres.env) file according to the [template](./.config/postgres.template.env).

## INIT

Any init script (sql, sh, ...) can be placed in the folder [.init](./.init). Ex [mydb_init.sql](./.init/mydb_init.sql) :
```sql
CREATE DATABASE some_db;
CREATE USER some_user WITH ENCRYPTED PASSWORD 'some_password';
GRANT ALL PRIVILEGES ON DATABASE some_db TO some_user;
```