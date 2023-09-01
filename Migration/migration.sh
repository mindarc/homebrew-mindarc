#!/bin/bash

# Step 1: Accept username, password, and source database name as inputs
read -p "Enter MySQL Username: " mysql_username
read -s -p "Enter MySQL Password: " mysql_password
echo
read -p "Enter Source Database Name: " source_database

# Step 2: Check if the migration directory already exists
migration_dir=~/migration
if [ -d "$migration_dir" ]; then
    echo "Migration directory '$migration_dir' already exists. Skipping directory creation."
else
    # Create a migration directory if it doesn't exist
    mkdir -p "$migration_dir"
fi

# Step 3: Backup the MySQL database
echo "Backing up existing database $source_database"
timestamp=$(date +%d%m%y%H%M%S)
backup_file="~/migration/${source_database}-backup-${timestamp}.sql"
mysqldump -u "$mysql_username" -p"$mysql_password" "$source_database" > "$backup_file"

# Step 4: Create my.cnf file if it doesn't exist
mycnf_path="/etc/mysql/my.cnf"
config_lines="[mysqld]
bind-address=0.0.0.0
log-bin=bin.log
log-bin-index=bin-log.index
max_binlog_size=100M
binlog_format=row
server-id=1
log_bin=/var/log/mysql/mysql-bin.log
expire_logs_days=3
enforce-gtid-consistency=ON
gtid-mode=ON
"

if [ -e "$mycnf_path" ]; then
    # Append the configuration lines to the end of the file
    echo "$config_lines" | sudo tee -a "$mycnf_path" > /dev/null
    echo "Appended to existing my.cnf file."
else
    # Create my.cnf file with the configuration lines
    echo "$config_lines" | sudo tee "$mycnf_path" > /dev/null
    echo "Created my.cnf file."
fi

# Step 5: Create MySQL user and grants if it doesn't already exist
user_exists=$(mysql -u "$mysql_username" -p"$mysql_password" -e "SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = 'migration_user' AND host = '%');" | awk '{print $2}')
if [ "$user_exists" -eq 1 ]; then
    echo "User 'migration_user' already exists. Adding additional permissions..."
    mysql -u "$mysql_username" -p"$mysql_password" <<MYSQL_SCRIPT
    GRANT SELECT, INSERT, UPDATE, DELETE, SHOW VIEW, LOCK TABLES ON \`${source_database}\`.* TO 'migration_user'@'%';
    FLUSH PRIVILEGES;
MYSQL_SCRIPT
else
    echo "Creating user 'migration_user'..."
    mysql -u "$mysql_username" -p"$mysql_password" <<MYSQL_SCRIPT
    CREATE USER 'migration_user'@'%' IDENTIFIED BY '$mysql_password';
    GRANT PROCESS, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'migration_user'@'%';
    GRANT SELECT, INSERT, UPDATE, DELETE, SHOW VIEW, LOCK TABLES ON \`${source_database}\`.* TO 'migration_user'@'%';
    GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER ON \`_vt\`.* TO 'migration_user'@'%';
    FLUSH PRIVILEGES;
MYSQL_SCRIPT

fi
# Step 6: Terminate script if tables without a primary key exist
tables_without_primary_key=$(mysql -u "$mysql_username" -p"$mysql_password" -N -e "SELECT table_name
FROM information_schema.tables
WHERE table_schema = '$source_database'
AND table_name NOT IN (
    SELECT table_name
    FROM information_schema.key_column_usage
    WHERE constraint_name = 'PRIMARY'
    AND table_schema = '$source_database'
);")

if [ -n "$tables_without_primary_key" ]; then
    echo "Ending script due to tables without a primary key in database: $source_database:"
    echo "$tables_without_primary_key"
    exit 1  # Exit with an error code
fi

# Step 7: Set MySQL global variables for the source database, if GTID_MODE is not already ON (Note - this should be already done by my.cnf)
gtid_status=$(mysql -u "$mysql_username" -p"$mysql_password" -N -e "SHOW VARIABLES LIKE 'gtid_mode';" | awk '{print $2}')
if [ "$gtid_status" != "ON" ]; then
    mysql -u "$mysql_username" -p"$mysql_password" <<MYSQL_SCRIPT
    SET @@GLOBAL.EXPIRE_LOGS_days=3;
    SET @@GLOBAL.ENFORCE_GTID_CONSISTENCY = ON;
    SET @@GLOBAL.GTID_MODE = OFF_PERMISSIVE;
    SET @@GLOBAL.GTID_MODE = ON_PERMISSIVE;
    SET @@GLOBAL.GTID_MODE = ON;
MYSQL_SCRIPT
else
    echo "GTID_MODE is already set to ON. Skipping GTID-related settings."
fi

# Step 8: Generate foreign key removal queries
sql_output=$(mysql -u "$mysql_username" -p"$mysql_password" -N -D "$source_database" <<MYSQL_SCRIPT
SELECT * FROM information_schema.TABLE_CONSTRAINTS tc;
SELECT CONCAT('ALTER TABLE ', TABLE_SCHEMA, '.', TABLE_NAME, ' DROP CONSTRAINT ', CONSTRAINT_NAME, ';')
FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS
WHERE CONSTRAINT_TYPE = 'FOREIGN KEY' AND TABLE_SCHEMA = '$source_database';
SELECT
CONCAT('ALTER TABLE ', table_name, ' DROP FOREIGN KEY ', constraint_name, ';') AS drop_statement
FROM
information_schema.key_column_usage
WHERE
referenced_table_name IS NOT NULL
AND table_schema = '$source_database';
MYSQL_SCRIPT
)

# Execute each row as a separate SQL command
echo "$sql_output" | while read -r sql_command; do
  mysql -u "$mysql_username" -p"$mysql_password" -D "$source_database" -e "$sql_command"
done

echo "MySQL migration setup and SQL commands executed for database: $source_database."

