#!/bin/bash

########### Defines
base_path=$( readlink -f `dirname $0` )
log_file=$base_path/`basename $0 .sh`.log
lockfile=$base_path/`basename $0 .sh`.lck
pid=$$
radar_short_codes='COR ALM SAN BAR BAD PMA LPA MAD MAL MUR LID SEV VAL SSE ZAR'

# Distribution paths
dist_peninsula='/home/cristhian/Documents/2020_03_13__AemetRadarWebChanges/dist'
dist_canary='/home/cristhian/Documents/2020_03_13__AemetRadarWebChanges/dist_can'
dist_donosti=''
dist_madrid=''

dist_uid=1000
dist_gid=1000

# Used to download the images
temp_dir=$(mktemp -d)
# File used to store the filename of the available file to download. Changes each time the data is updated by AEMET
last_downloaded_filename="$base_path/`basename $0 .sh`__last_downloaded_filename.txt"

# Backup if needed
do_backup=YES
backup_dir='/home/cristhian/Documents/2020_03_13__AemetRadarWebChanges/backup'

aemet_download_endpoint='https://www.aemet.es/es/api-eltiempo/radar/download/PPI'
# Control execution
continue_processing="NO"


########### Functions
function log {
	echo "`date` [$pid] - $1"
	echo "`date` [$pid] - $1" >> $log_file
}

function getRadarName {
	case $1 in
		'COR') echo 'corunha' ;;
		'ALM') echo 'almeria' ;;
		'SAN') echo 'santander' ;; ## TODO CHECK
		'BAR') echo 'barcelona' ;;
		'BAD') echo 'caceres' ;;
		'PMA') echo 'mallorca' ;;
		'LPA') echo 'gran_canaria' ;;
		'MAD') echo 'madrid' ;;
		'MAL') echo 'malaga' ;;
		'MUR') echo 'murcia' ;;
		'LID') echo 'palencia' ;;
		'SEV') echo 'sevilla' ;;
		'VAL') echo 'valencia' ;;
		'SSE') echo 'donosti' ;; ## TODO CHECK
		'ZAR') echo 'zaragoza' ;;
	esac
}

function getLastDownloadedFilename {
	local filename=''
	# Check that the variable is set and the file exists
	if [ -n $last_downloaded_filename ] && [ -f $last_downloaded_filename ]; then
		filename=`cat $last_downloaded_filename`
	fi

	echo $filename
}

function setLastDownloadedFilename {
	local filename=$1

	echo $filename > $last_downloaded_filename
}

function downloadImages {
	local previous_dir=$(pwd)
	local working_dir=$1

	# Change dir as curl with -JO options downloads in the current dir
	cd $working_dir

	log "INFO: Downloading images..."
	# Curl options used:
	#	-I		HEAD HTTP Request
	#	-L		Follow redirects
	# 	-s 		Silent
	#	-f		Fail on server errors
	#	-OJ		Download the file using the Content-Disposition filename
	#	-w		Echo to Stout the filename
	#	-m 		Timeout

	# First issue a HEAD request only to retrieve the Content-Disposition Header with the server filename.
	file_to_download=$(curl -I -L -s -f -JO -w "%{filename_effective}" -m 30 ${aemet_download_endpoint})
	exitcode=$?

	if [ $exitcode -eq 0 ]; then
		log "INFO: File found: $file_to_download"

		# Read the filename of the last downloaded file to see if the contents were updated
		last_downloaded=$( getLastDownloadedFilename )

		if [ "$file_to_download" == "$last_downloaded" ]; then
			log "INFO: File has already been processed."
		else
			# Delete the file created by the HEAD request. Only contain the headers
			rm $file_to_download

			# Request the actual file
			file_downloaded=$(curl -L -s -f -JO -w "%{filename_effective}" -m 30 ${aemet_download_endpoint})
			exitcode=$?

			if [ $exitcode -eq 0 ]; then
				log "INFO: File downloaded: $file_downloaded"

				if [ `file -b $working_dir/$file_downloaded | grep "gzip compressed data" | wc -l` -eq 1 ]; then
					if [ `stat -c %s $working_dir/$file_downloaded` -gt 0 ]; then
						# Extract the update epoch from filename
						update_epoch=$(echo $file_downloaded | sed -n -E "s/^descargas_([0-9]{10}).tar.gz$/\1/p")
						log "INFO: Data update corresponds to `date -d @$update_epoch`"

						# Decompress the file
						tar -xzf $working_dir/$file_downloaded -C $working_dir

						# Remove ECHOTOP and accumulation files
						find $working_dir -type f -not -name "*PPI.Z*" -exec rm {} \;

						# Set the flag to continue processing
						continue_processing="YES"

						# Save the filename for next downlods
						setLastDownloadedFilename $file_downloaded
					else
						log "SEVERE: file $working_dir/$file_downloaded size is 0!"
						rm -f $working_dir/$file_downloaded
					fi
				else
					log "SEVERE: file $working_dir/$file_downloaded is not a gZip file!"
					rm -f $working_dir/$file_downloaded
				fi

			else
				log "WARNING: Received server errors on GET HTTP request."
				rm -f $working_dir/$file_downloaded
			fi
		fi

	else
		log "WARNING: Received server errors on the HEAD HTTP request."
		rm -f $working_dir/$file_to_download
	fi

	# Return to the previous directory
	cd $previous_dir
}

# Used to mantain the filename as expected from legacy programs
function renameFiles {
	local working_dir=$1
	for file in $working_dir/*
	do
		local basename=$(basename $file)

		# Sample file: down_SAN200313131000.PPI.Z_005_240.tif
		local date=$(echo $basename | sed -n -E "s/^down_\w{3}([0-9]{12}).*$/\1/p")
		# The date from the file only contains the last 2 digits of the year
		local year="20${date:0:2}"
		local month="${date:2:2}"
		local day="${date:4:2}"
		local hour="${date:6:2}"
		local minute="${date:8:2}"
		
		local radar_code=$(echo $basename | sed -n -E "s/^down_(\w{3}).*$/\1/p")
		local radar_name=$( getRadarName $radar_code )
		
		# Expected legacy format: 202003131240_valencia.tif
		local name="${year}${month}${day}${hour}${minute}_$radar_name.tif"
		log "INFO: File $name"
		mv $file $working_dir/$name
	done
}

function backupFiles {
	local working_dir=$1

	for file in $working_dir/*
	do
		local basename=$(basename $file)
		local date=$(echo $basename | sed -n -E "s/^([0-9]{12}).*$/\1/p")
		local year="${date:0:4}"
		local month="${date:4:2}"
		local day="${date:6:2}"

		target_backup_dir="$backup_dir/${year}_${month}/$day"
		if [ ! -e $target_backup_dir ]; then mkdir -p $target_backup_dir; fi

		cp $file $target_backup_dir
	done
}

function hideFiles {
	local working_dir=$1
	local i=0

	for i in `ls $working_dir`; do
		mv $working_dir/$i $working_dir/.$i
	done
}

function unhideFiles {
	local working_dir=$1
	local i=0

	for i in `find $working_dir -maxdepth 1 -type f -name "\.*"`; do
		dir=`dirname $i`
		file=`basename $i`
		mv $dir/$file $dir/${file/\./}
	done
}

function distributeFiles {
	local working_dir=$1
	
	# Hide files
	hideFiles $working_dir

	# Distribute Donosti files
	for j in $dist_donosti; do
		if [ ! -e $j ]; then mkdir -p $j; fi
		cp $working_dir/.*_donosti.tif $j
		chown -R $dist_uid:$dist_gid $j
		unhideFiles $j
	done

	# Distribute Madrid files
	for j in $dist_madrid; do
		if [ ! -e $j ]; then mkdir -p $j; fi
		cp $working_dir/.*_madrid.tif $j
		chown -R $dist_uid:$dist_gid $j
		unhideFiles $j
	done

	# Distribute Canarias files
	for j in $dist_canary; do
		if [ ! -e $j ]; then mkdir -p $j; fi
		cp $working_dir/.*_gran_canaria.tif $j
		chown -R $dist_uid:$dist_gid $j
		unhideFiles $j
	done
	rm -f $working_dir/.*_gran_canaria.tif

	# Distribute individual radars
	for j in $dist_peninsula; do
		if [ ! -e $j ]; then mkdir -p $j; fi
		cp $working_dir/.*.tif $j
		chown -R $dist_uid:$dist_gid $j
		unhideFiles $j
	done
	rm -f $working_dir/.*.tif
}

function getAemetRadarImages {
	# Download into the temporary dir
	downloadImages $temp_dir

	if [ "$continue_processing" == "YES" ]; then
		# Rename the files. Needed for legacy applications
		renameFiles $temp_dir

		# Backup
		if [ "$do_backup" == "YES" ]; then
			log "INFO: Backup"
			backupFiles $temp_dir
		fi

		log "INFO: Distribute"
		distributeFiles $temp_dir
	fi

	# Cleanup
	rm -rf $temp_dir
}


########### Main
(
	log "INFO: Start"

	if flock -n 201; then
		echo $pid >> $lockfile
		getAemetRadarImages
		rm -f $lockfile
	else
		log "FATAL ERROR: Script is already executing. Exiting now."
	fi

	log "INFO: Done"
) 201>$lockfile

exit 0