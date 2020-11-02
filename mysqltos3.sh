#!/bin/bash

# Based on https://github.com/woxxy/MySQL-backup-to-Amazon-S3
# Full backups every start of month and week. Differential backups the rest of days.
# Param: auto | month | week | day
# By default: auto
#
set -e #stops execution if a variable is not set
set -u #stop execution if something goes wrong

# check binaries
which pigz > /dev/null
which s3cmd > /dev/null
which qpress > /dev/null
which innobackupex > /dev/null

# change these variables to what you need
MYSQLROOT="root"
MYSQLPASS='pass'
MYCNF="/etc/my.cnf"
HOST="localhost"
PORT="3306"
SOCKET="/var/lib/mysql/mysql.sock"
S3BUCKET="db-backups"
# Path for full backup and differential backup. Must end with /
BACKUP_PATH="/"
# Name of backup dir, within BACKUP_PATH
BACKUP_DIRNAME="backup_mysql"
# the following line prefixes the backups with the defined directory. it must be blank or end with a /
S3PATH="hawk/"
# when running via cron, the PATHs MIGHT be different
PERCONA_BACKUP_COMMAND="/usr/bin/innobackupex"
# extras
ARGS="--parallel=$(nproc --all) --compress --compress-threads=$(nproc --all) --no-version-check --no-timestamp --extra-lsndir=/tmp --history --slave-info --rsync"

# Week num, from 01 to 53 starting Monday
week_curr=$(date +"%V")
# Week num, from 01 to 53 starting Monday
week_minus2=$(date --date="2 weeks ago" +"%V")
# Week num, from 01 to 53 starting Monday
month_curr=$(date +"%m")
# Month minus 2 (1..12)
month_minus2=$(date --date="2 months ago" +"%m")

DATESTAMP=$(date +"_%Y%m%d_%H%M%S")
# Day: 01-31
DAY=$(date +"%d")
# Day of week: Monday-Sunday
DAYOFWEEK=$(date +"%u")

PERIOD=${1-auto}

if [ ${PERIOD} = "auto" ]; then
        if [ ${DAY} = "01" ]; then
                PERIOD=month
        elif [ ${DAYOFWEEK} = "1" ]; then
                PERIOD=week
        else
                PERIOD=day
        fi
fi

if [ ${PERIOD} = "month" ]; then
        CURRENT_MINUS2="month_${month_minus2}"
        CURRENT="month_${month_curr}"
elif [ ${PERIOD} = "week" ]; then
        CURRENT_MINUS2="week_${week_minus2}"
        CURRENT="week_${week_curr}"
else
        CURRENT="day_$(date +"%u")"
fi

echo "*************** Selected period: $PERIOD. Current: $CURRENT *************"

echo "*************** Backing up the databases... *****************************"

if [ ${PERIOD} = "week" ] || [ ${PERIOD} = "month" ] ; then
        # Remove previous full-backup from local filesystem
        echo "*************** Removing previous full backup dir ***********************"
        BACKUP_DIRNAME=${BACKUP_DIRNAME}_full
        rm -rf ${BACKUP_PATH}${BACKUP_DIRNAME}
        # perform backup
        ${PERCONA_BACKUP_COMMAND} --defaults-file=${MYCNF} --host=${HOST} --port=${PORT} --user=${MYSQLROOT} --password=${MYSQLPASS} --socket=${SOCKET} ${ARGS} ${BACKUP_PATH}${BACKUP_DIRNAME}
else
        # Remove previous differential-backup
        echo "*************** Removing previous differential backup dir ***************"
        rm -rf ${BACKUP_PATH}${BACKUP_DIRNAME}
        # perform backup
        ${PERCONA_BACKUP_COMMAND} --defaults-file=${MYCNF} --host=${HOST} --port=${PORT} --user=${MYSQLROOT} --password=${MYSQLPASS} --socket=${SOCKET} ${ARGS} --incremental ${BACKUP_PATH}${BACKUP_DIRNAME} --incremental-basedir=${BACKUP_PATH}${BACKUP_DIRNAME}_full
fi

# archiving all databases to a file
echo "*************** Started archiving the databases to a file... ************"
echo "tar -I pigz -cf ${BACKUP_PATH}${BACKUP_DIRNAME}${DATESTAMP}.tar.gz -C ${BACKUP_PATH} ${BACKUP_DIRNAME}"
tar -I pigz -cf ${BACKUP_PATH}${BACKUP_DIRNAME}${DATESTAMP}.tar.gz -C ${BACKUP_PATH} ${BACKUP_DIRNAME}
echo "*************** Done archiving the databases. ***************************"

# upload all databases
echo "*************** Uploading the new backup... *****************************"
s3cmd put --acl-private -f ${BACKUP_PATH}${BACKUP_DIRNAME}${DATESTAMP}.tar.gz s3://${S3BUCKET}/${S3PATH}${CURRENT}/
echo "*************** New backup uploaded. ************************************"

# remove old backups from 2 periods ago, if period is month or week, plus daily differential backups
if [ ${PERIOD} = "week" ] || [ ${PERIOD} = "month" ] ; then
        echo "Removing old backup (2 ${PERIOD}s ago)..."
        s3cmd del --recursive s3://${S3BUCKET}/${S3PATH}${CURRENT_MINUS2}/
        echo "Old backup removed."
        echo "Removing daily differential backups..."
        week_days=(day_1 day_2 day_3 day_4 day_5 day_6 day_7)
        for i in "${week_days[@]}"
        do
                echo "Removing $i"
                s3cmd del --recursive s3://${S3BUCKET}/${S3PATH}${i}/
        done
fi

echo "*************** Removing the cache files... *****************************"
# remove archived databases dump
rm ${BACKUP_PATH}${BACKUP_DIRNAME}${DATESTAMP}.tar.gz
echo "*************** Cache files removed. ************************************"
echo "All done."
