#!/bin/bash

# Step 1: Accept username, password, and source database name as inputs
read -p "Enter MySQL Username: " mysql_username
read -s -p "Enter MySQL Password: " mysql_password
echo
read -p "Enter Source Database Name: " source_database

# Step 2: Check if the migration directory already exists
echo "Checking if migration folder exists in home directory..."
migration_dir=~/migration
if [ -d "$migration_dir" ]; then
    echo "Migration directory '$migration_dir' already exists. Skipping directory creation."
else
    # Create a migration directory if it doesn't exist
    mkdir -p "$migration_dir"
fi

# Step 3: Backup the MySQL database
echo "Backing up existing database $source_database..."
timestamp=$(date +%d%m%y%H%M%S)
backup_file="~/migration/${source_database}-backup-${timestamp}.sql"
mysqldump -u "$mysql_username" -p"$mysql_password" "$source_database" > "$backup_file"

# Step 4: Create my.cnf file if it doesn't exist
echo "Generating mysql configuration settings..."
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
echo "Checking if migration_user has been created..."
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

# Step 6: Check if UFW is enabled and add rules if necessary
echo "Checking ufw settings..."
ufw_status=$(sudo ufw status | grep "Status: active")

if [ -n "$ufw_status" ]; then
    echo "UFW is enabled. Adding rules if they don't exist..."
    
    # Define the IP addresses to allow
    allowed_ips=("3.24.39.244" "54.252.39.42" "54.253.218.226" "3.209.149.66" "3.215.97.46" "34.193.111.15")

    # Define the port to allow (3306 for MySQL)
    port="3306"

    # Iterate over the allowed IPs and add the UFW rules
    for ip in "${allowed_ips[@]}"; do
        rule_exists=$(sudo ufw status | grep "$ip $port")
        if [ -z "$rule_exists" ]; then
            sudo ufw allow from "$ip" to any port "$port"
            echo "Added UFW rule to allow access from $ip to port $port."
        else
            echo "UFW rule to allow access from $ip to port $port already exists. Skipping."
        fi
    done
else
    echo "UFW is not enabled. Skipping rule addition."
fi

# Step 7: Terminate script if tables without a primary key exist
echo "Checking if tables exist in $source_database without a primary key..."
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

:'
Not required due to my.cnf
# Step 8: Set MySQL global variables for the source database, if GTID_MODE is not already ON
gtid_status=$(mysql -u "$mysql_username" -p"$mysql_password" -N -e "SHOW VARIABLES LIKE 'gtid_mode';" | awk '{print $2}')
#if [ "$gtid_status" != "ON" ]; then
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
'

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
