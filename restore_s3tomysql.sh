#!/bin/bash

set -e #stops execution if a variable is not set
set -u #stop execution if something goes wrong

# check binaries
which pigz > /dev/null
which s3cmd > /dev/null
which qpress > /dev/null
which xtrabackup > /dev/null

# change these variables to what you need
MEM="8G"
S3BUCKET="db-backups"
# Path for full backup and differential backup. Must end with /
BACKUP_PATH="/"
# Name of backup dir, within BACKUP_PATH
BACKUP_DIRNAME="backup_mysql"
# the following line prefixes the backups with the defined directory. it must be blank or end with a /
S3PATH="hawk/"
# when running via cron, the PATHs MIGHT be different
PERCONA_BACKUP_COMMAND="/usr/bin/xtrabackup"
# extras
ARGS="--use-memory=${MEM} --parallel=$(nproc --all)"

# colored shell output
red_color=`tput setaf 1`
green_color=`tput setaf 2`
reset_color=`tput sgr0`

# create directory to restore files
RESTORED_DIR=${BACKUP_PATH}${BACKUP_DIRNAME}_restored
if [ ! -d "$RESTORED_DIR" ] ; then
  mkdir -p $RESTORED_DIR
fi

first_week_from_month=$(date -d "$(date +"%Y%m01")" +"%W")
week_curr=$(date +"%V")
month_curr=$(date +"%m")
day_of_the_week=$(date +"%u")

# choose between using the latest weekly or monthly backup
if [ $week_curr -gt $first_week_from_month ]
then
  PERIOD=week
  CURRENT=$week_curr
else
  PERIOD=month
  CURRENT=$month_curr
fi

echo -e "*************** Selected period: $PERIOD. Current: $CURRENT **********************\n"

echo -e "*************** Downloading full backup for ${PERIOD}_${CURRENT} *********************"
s3cmd get --force s3://${S3BUCKET}/${S3PATH}${PERIOD}_${CURRENT}/*.tar.gz ${RESTORED_DIR}/

echo -e "*************** Downloading last differential backup for day_${day_of_the_week}"
s3cmd get --force s3://${S3BUCKET}/${S3PATH}day_${day_of_the_week}/*.tar.gz ${RESTORED_DIR}/

echo -e "*************** Decompressing backups ***********************************\n"
for file in `ls ${RESTORED_DIR}/*.tar.gz` ;
do
  echo -e "*************** Decompressing $file to $RESTORED_DIR\n"
  tar -I pigz -xivf $file --directory ${RESTORED_DIR}
done

# differential backups will be placed in $RESTORED_DIR/$BACKUP_DIRNAME
# full backups will be placed in ${RESTORED_DIR}/${BACKUP_DIRNAME}_full
RESTORED_DIFF_DIR=${RESTORED_DIR}/${BACKUP_DIRNAME}/
RESTORED_FULL_DIR=${RESTORED_DIR}/${BACKUP_DIRNAME}_full/

${PERCONA_BACKUP_COMMAND} --decompress --parallel=$(nproc --all) --remove-original --target-dir=${RESTORED_FULL_DIR}
${PERCONA_BACKUP_COMMAND} --decompress --parallel=$(nproc --all) --remove-original --target-dir=${RESTORED_DIFF_DIR}

if [ -d "${RESTORED_DIFF_DIR}" ] && [ -d "${RESTORED_FULL_DIR}" ] ;
then
  echo -e "*************** Merging differential and full backups ********************\n"
  ${PERCONA_BACKUP_COMMAND} --defaults-file=${RESTORED_FULL_DIR}/backup-my.cnf --prepare --apply-log-only ${ARGS} --target-dir=${RESTORED_FULL_DIR}
  ${PERCONA_BACKUP_COMMAND} --defaults-file=${RESTORED_FULL_DIR}/backup-my.cnf --prepare ${ARGS} --target-dir=${RESTORED_FULL_DIR} --incremental-dir=${RESTORED_DIFF_DIR}
  echo -e "\n${green_color}[NOTICE] Merged backups available in: ${RESTORED_FULL_DIR} ${reset_color}"
  echo -e "\n${green_color}${PERIOD}_${CURRENT} checkpoints info ${reset_color}\n"
  cat ${RESTORED_FULL_DIR}/xtrabackup_checkpoints
  echo -e "\n*************** Removing the cache files... ******************************"
  # remove compressed databases dump
  rm -rf ${RESTORED_DIR}/*.tar.gz
  echo -e "*************** Cache files removed. *************************************\n"
  echo "All done."
else
  echo -e "${red_color}[ERROR] Something got bR0ken, please check output as recovered dirs are not present${reset_color}\n"
  echo "Please check directory: ${RESTORED_DIR}"
  exit 1
fi
