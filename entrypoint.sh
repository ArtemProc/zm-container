#!/bin/bash
# ZoneMinder Dockerfile entrypoint script
# inspired by Andrew Bauer <zonexpertconsulting@outlook.com>
# edited by ArtemProc


###############
# SUBROUTINES #
###############

# Find ciritical files and perform sanity checks
initialize () {

    # check if remote db credentials have been given and set properly
    counter=0
    for CREDENTIAL in $ZM_DB_HOST $ZM_DB_USER $ZM_DB_PASS $ZM_DB_PASS_FILE $ZM_DB_NAME; do
        if [ -n "$CREDENTIAL" ]; then
            counter=$((counter+1))
        fi
    done

    # counter = 0 means a local database
    # counter = 4 means a remote database
    # counter != 0 or 4 means the credentials were not specified correctly and we should fail
    remoteDB=0
    serverbins="my_print_defaults mysqld_safe"
    if [ "$counter" -eq "4" ]; then
        echo " * Remote database credentials detected. Continuing..."
        remoteDB=1
        serverbins=""
    elif [ "$counter" -ne "0" ]; then
        echo " * Fatal: Remote database credentials not set correctly."
        exit 97
    fi

    # Check to see if this script has access to all the commands it needs
    for CMD in cat grep install ln mysql mysqladmin mysqlshow sed sleep su tail usermod head file $serverbins; do
      type $CMD &> /dev/null

      if [ $? -ne 0 ]; then
        echo
        echo "ERROR: The script cannot find the required command \"${CMD}\"."
        echo
        exit 1
      fi
    done

    # Look in common places for the mysqld/MariaDB executable
    for FILE in "/usr/sbin/mysqld" "/usr/libexec/mysqld" "/usr/local/sbin/mysqld" "/usr/local/libexec/mysqld"; do
        if [ -f $FILE ]; then
            MYSQLD=$FILE
            break
        fi
    done

    # Look in common places for the apache executable commonly called httpd or apache2
    for FILE in "/usr/sbin/httpd" "/usr/sbin/apache2"; do
        if [ -f $FILE ]; then
            HTTPBIN=$FILE
            break
        fi
    done

    # Look in common places for the zoneminder config file - zm.conf
    for FILE in "/etc/zm.conf" "/etc/zm/zm.conf" "/usr/local/etc/zm.conf" "/usr/local/etc/zm/zm.conf"; do
        if [ -f $FILE ]; then
            ZMCONF=$FILE
            break
        fi
    done

    # Look in common places for the zoneminder startup perl script - zmpkg.pl
    for FILE in "/usr/bin/zmpkg.pl" "/usr/local/bin/zmpkg.pl"; do
        if [ -f $FILE ]; then
            ZMPKG=$FILE
            break
        fi
    done

    # Look in common places for the zoneminder dB update perl script - zmupdate.pl
    for FILE in "/usr/bin/zmupdate.pl" "/usr/local/bin/zmupdate.pl"; do
        if [ -f $FILE ]; then
            ZMUPDATE=$FILE
            break
        fi
    done

    # Look in common places for the zoneminder dB creation script - zm_create.sql
    for FILE in "/usr/share/zoneminder/db/zm_create.sql" "/usr/local/share/zoneminder/db/zm_create.sql"; do
        if [ -f $FILE ]; then
            ZMCREATE=$FILE
            break
        fi
    done

    # Look in common places for the php.ini relevant to zoneminder
    # Search order matters here because debian distros commonly have multiple php.ini's
    counter=0
    php_file_path=""
    for FILE in $(find /etc/php -type f -path "*/apache2/php.ini"); do
        php_file_path="$FILE"
        ((counter++))
    done

    if [[ $counter -eq 1 ]]; then
        PHPINI=$php_file_path
    else
        echo "File count is not equal to 1. Total files found: $counter"
        exit 98
    fi

    # Do we have php-fpm installed
    for FILE in "/usr/sbin/php-fpm"; do
        if [ -f $FILE ]; then
            PHPFPM=$FILE
        fi
    done

    for FILE in $ZMCONF $ZMPKG $ZMUPDATE $ZMCREATE $PHPINI $HTTPBIN $MYSQLD; do
        if [ -z $FILE ]; then
            echo
            echo "FATAL: This script was unable to determine one or more critical files. Cannot continue."
            echo
            echo "VARIABLE DUMP"
            echo "-------------"
            echo
            echo "Path to zm.conf: ${ZMCONF}"
            echo "Path to zmpkg.pl: ${ZMPKG}"
            echo "Path to zmupdate.pl: ${ZMUPDATE}"
            echo "Path to zm_create.sql: ${ZMCREATE}"
            echo "Path to php.ini: ${PHPINI}"
            echo "Path to Apache executable: ${HTTPBIN}"
            echo "Path to Mysql executable: ${MYSQLD}"
            echo
            exit 98
        fi
    done

    # Set the php-fpm socket owner
    if [ -e /etc/php-fpm.d/www.conf ]; then
        mkdir -p /var/run/php-fpm

        sed -E 's/^;(listen.(group|owner) = ).*/\1apache/g' /etc/php-fpm.d/www.conf | \
            sed -E 's/^(listen\.acl_users.*)/;\1/' > /etc/php-fpm.d/www.conf.n

        if [ $? -ne 0 ]; then
            echo
            echo " * Unable to update php-fpm file"
            exit 95
        fi

        mv -f /etc/php-fpm.d/www.conf.n /etc/php-fpm.d/www.conf
    fi
}

# Usage: get_mysql_option SECTION VARNAME DEFAULT
# result is returned in $result
# We use my_print_defaults which prints all options from multiple files,
# with the more specific ones later; hence take the last match.
get_mysql_option (){
        result=`my_print_defaults "$1" | sed -n "s/^--$2=//p" | tail -n 1`
        if [ -z "$result" ]; then
            # not found, use default
            result="$3"
        fi
}

# Return status of mysql service
mysql_running () {
    if [ "$remoteDB" -eq "1" ]; then
        mysqladmin ping -u${ZM_DB_USER} -p${ZM_DB_PASS} -h${ZM_DB_HOST} > /dev/null 2>&1
    else
        mysqladmin ping > /dev/null 2>&1
    fi
    local result="$?"
    if [ "$result" -eq "0" ]; then
        echo "1" # mysql is running
    else
        echo "0" # mysql is not running
    fi
}

# Blocks until mysql starts completely or timeout expires
mysql_timer () {
    timeout=60
    count=0
    while [ "$(mysql_running)" -eq "0" ] && [ "$count" -lt "$timeout" ]; do
        sleep 1 # Mysql has not started up completely so wait one second then check again
        count=$((count+1))
    done

    if [ "$count" -ge "$timeout" ]; then
       echo " * Warning: Mysql startup timer expired!"
    fi
}

mysql_datadir_exists() {
    if [ -d /var/lib/mysql/mysql ]; then
        echo "1" # datadir exists
    else
        echo "0" # datadir does not exist
    fi
}

zm_db_exists() {
    if [ "$remoteDB" -eq "1" ]; then
        mysqlshow -u${ZM_DB_USER} -p${ZM_DB_PASS} -h${ZM_DB_HOST} ${ZM_DB_NAME} > /dev/null 2>&1
    else
        mysqlshow zm > /dev/null 2>&1
    fi
    RETVAL=$?
    if [ "$RETVAL" = "0" ]; then
        echo "1" # ZoneMinder database exists
    else
        echo "0" # ZoneMinder database does not exist
    fi
}

# The secret sauce to determine wether to use mysql_install_db
# or mysqld --initialize seems to be wether mysql_install_db is a shell
# script or a binary executable
use_mysql_install_db () {
    local result="$?"

    if [ "$result" -eq "0" ] && [ -n "$MYSQL_INSTALL_DB"  ]; then
        local contents=$(file -b "$MYSQL_INSTALL_DB")
        if [[ "$contents" =~ .*ASCII.text.executable.* ]]; then
            echo "1" # mysql_install_db is a shell script
        else
            echo "0" # mysql_install_db is a binary
        fi
    else
        echo "0" # mysql_install_db does not exist
    fi
}

# mysql service management
start_mysql () {
    # determine if we are running mariadb or mysql then guess pid location
    if [ $(mysql --version |grep -ci mariadb) -ge "1" ]; then
        default_pidfile="/var/run/mariadb/mariadb.pid"
    else
        default_pidfile="/var/run/mysqld/mysqld.pid"
    fi

    # verify our guessed pid file location is right
    get_mysql_option mysqld_safe pid-file $default_pidfile
    mypidfile=$result
    mypidfolder=${mypidfile%/*}
    mysocklockfile=${mypidfolder}/mysqld.sock.lock

    if [ "$(mysql_datadir_exists)" -eq "0" ]; then
        echo " * First run of MYSQL, initializing DB."
        MYSQL_INSTALL_DB=$(type -p mysql_install_db)
        if [ "$(use_mysql_install_db)" -eq "1" ]; then
            ${MYSQL_INSTALL_DB} --user=mysql --datadir=/var/lib/mysql/ > /dev/null 2>&1
        else
            ${MYSQLD} --initialize-insecure --user=mysql --datadir=/var/lib/mysql/ > /dev/null 2>&1
        fi
    elif [ -e ${mysocklockfile} ]; then
        echo " * Removing stale lock file"
        rm -f ${mysocklockfile}
    fi
    # Start mysql only if it is not already running
    if [ "$(mysql_running)" -eq "0" ]; then
        echo -n " * Starting MySQL database server service"
        test -e $mypidfolder || install -m 755 -o mysql -g root -d $mypidfolder
        mysqld_safe --user=mysql --timezone="$TZ" > /dev/null 2>&1 &
        RETVAL=$?
        if [ "$RETVAL" = "0" ]; then
            echo "   ...done."
            mysql_timer # Now wait until mysql finishes its startup
        else
            echo "   ...failed!"
        fi
    else
        echo " * MySQL database server already running."
    fi

    mysqlpid=`cat "$mypidfile" 2>/dev/null`
}

# Check the status of the remote mysql server using supplied credentials
chk_remote_mysql () {
    EMPTYDATABASE=$(mysql -u$ZM_DB_USER -p$ZM_DB_PASS --host=$ZM_DB_HOST --batch --skip-column-names -e "use ${ZM_DB_NAME} ; show tables;" | wc -l )
    echo "DB Table Count is" $EMPTYDATABASE
    if [ "$remoteDB" -eq "1" ]; then
        echo -n " * Looking for remote database server"
        if [ "$(mysql_running)" -eq "1" ]; then
            echo "   ...found."
        else
            echo "   ...failed!"
            return
        fi
        echo -n " * Looking for existing remote database"
        if [ "$(zm_db_exists)" -eq "1" -a $EMPTYDATABASE -ne 0 ]; then
            echo "   ...found."
        else
            echo "   ...not found."
            echo -n " * Attempting to create remote database using provided credentials"
            mysql -u${ZM_DB_USER} -p${ZM_DB_PASS} -h${ZM_DB_HOST} < $ZMCREATE > /dev/null 2>&1
            RETVAL=$?
            if [ "$RETVAL" = "0" ]; then
                echo "   ...done."
            else
                echo "   ...failed!"
                echo " * Error: Remote database must be manually configred."
            fi
        fi
    else
        # This should never happen
        echo " * Error: chk_remote_mysql subroutine called but no sql credentials were given!"
    fi
}

# Apache service management
start_http () {

    # CentOS/Rocky 8 ships with php-fpm enabled, we need to start it
    # Not tested on other distros please provide feedback
    if [ -n "$PHPFPM" ]; then
        echo -n " * Starting php-fpm web service"
        $PHPFPM &> /dev/null
        RETVAL=$?

        if [ "$RETVAL" -eq "0" ]; then
            echo "   ...done."
        else
            echo "   ...failed!"
            exit 1
        fi
    fi

    echo -n " * Starting Apache http web server service"
    # Debian requires we load the contents of envvars before we can start apache
    if [ -f /etc/apache2/envvars ]; then
        source /etc/apache2/envvars
    fi
    $HTTPBIN -k start > /dev/null 2>&1
    RETVAL=$?
    if [ "$RETVAL" = "0" ]; then
        echo "   ...done."
    else
        echo "   ...failed!"
        exit 1
    fi
}

# ZoneMinder service management
start_zoneminder () {
    echo -n " * Starting ZoneMinder video surveillance recorder"
    # Call zmupdate.pl here to upgrade the dB if needed. 
    # Otherwise zm fails after an upgrade, due to dB mismatch
    $ZMUPDATE --nointeractive
    $ZMUPDATE --nointeractive -f

    $ZMPKG start > /dev/null 2>&1
    RETVAL=$?
    if [ "$RETVAL" = "0" ]; then
        echo "   ...done."
    else
        echo "   ...failed!"
        exit 1
    fi
}

cleanup () {
    echo " * SIGTERM received. Cleaning up before exiting..."
    kill $mysqlpid > /dev/null 2>&1
    $HTTPBIN -k stop > /dev/null 2>&1
    sleep 5
    exit 0
}

################
# MAIN PROGRAM #
################

echo "MAIN START"
initialize

# Set the timezone before we start any services
if [ -z "$TZ" ]; then
    TZ="UTC"
fi

echo "Setting PHP timezone"
sed -i "s|;date\.timezone =.*|date.timezone = ${TZ}|" $PHPINI

if [ -L /etc/localtime ]; then
    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
fi
if [ -f /etc/timezone ]; then
    echo "$TZ" > /etc/timezone
fi

if [ -d "/var/lib/mysql" ]; then
  chown -R mysql:mysql /var/lib/mysql/
fi

# Configure then start Mysql
if [ "$remoteDB" -eq "1" ]; then
    if [ -n "$ZM_DB_PASS_FILE" ]; then
        ZM_DB_PASS=$(cat $ZM_DB_PASS_FILE)
    fi

    sed -i -e "s/ZM_DB_NAME=.*$/ZM_DB_NAME=$ZM_DB_NAME/g" $ZMCONF
    sed -i -e "s/ZM_DB_USER=.*$/ZM_DB_USER=$ZM_DB_USER/g" $ZMCONF
    sed -i -e "s/ZM_DB_PASS=.*$/ZM_DB_PASS=$ZM_DB_PASS/g" $ZMCONF
    sed -i -e "s/ZM_DB_HOST=.*$/ZM_DB_HOST=$ZM_DB_HOST/g" $ZMCONF
    chk_remote_mysql
else
    usermod -d /var/lib/mysql/ mysql > /dev/null 2>&1
    start_mysql

    mysql -u root -e "CREATE USER 'zmuser'@'localhost' IDENTIFIED BY 'zmpass';"
    mysql -u root -e "GRANT ALL PRIVILEGES ON *.* TO 'zmuser'@'localhost';"

    if [ "$(zm_db_exists)" -eq "0" ]; then
        echo " * First run of mysql in the container, creating ZoneMinder dB."
        mysql -u root < $ZMCREATE
    else
        echo " * ZoneMinder dB already exists, skipping table creation."
    fi
fi

# Ensure we shutdown our services cleanly when we are told to stop
trap cleanup SIGTERM

# check if Directory inside of /var/cache/zoneminder are present.
ZM_CACHE_FOLDER=/var/cache/zoneminder/events
if [ ! -d "$ZM_CACHE_FOLDER" ]; then
    echo "Creating /var/cache/zoneminder subdirectories and setting permissions"
    mkdir -p /var/cache/zoneminder/{events,images,temp,cache}
    chown -R root:www-data /var/cache/zoneminder
    chmod -R 770 /var/cache/zoneminder
elif [ -d "$ZM_CACHE_FOLDER" ]; then
    echo "Checking $ZM_CACHE_FOLDER permissions "
    folder_owner=$(stat -c "%U" "$ZM_CACHE_FOLDER")
    folder_group=$(stat -c "%G" "$ZM_CACHE_FOLDER")
    if  [[ "$folder_owner" != "root" || "$folder_group" != "www-data" ]]; then
        echo "FIXING $ZM_CACHE_FOLDER permissions "
        chown -R root:www-data /var/cache/zoneminder
        chmod -R 770 /var/cache/zoneminder
    fi
fi

echo "chown and chmod /etc/zm and /var/log/zm"
chown -R root:www-data /etc/zm
chown -R www-data:www-data /var/log/zm
chmod -R 770 /etc/zm /var/log/zm
[[ -e /run/zm ]] || install -m 0750 -o www-data -g www-data -d /run/zm

# Start Apache
start_http

# Start ZoneMinder
start_zoneminder

# tail logs while running
tail -F /var/log/zoneminder/zm*.log /var/log/zm/zm*.log