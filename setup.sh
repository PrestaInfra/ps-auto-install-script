#!/bin/bash


LOG_FILE=logs/setup.log
CURRENT_DATE_TIME=$(date +%F%H%M%S)
DEFAULT_PS_PROJECT_NAME=ps_project_${CURRENT_DATE_TIME}

## WORKDIR GENERATOR
project_workdir_generator() {

	if [ ! -z "$PS_PROJECT_NAME" ]; then
		PS_PROJECT_NAME_PURIFIED=$(echo $PS_PROJECT_NAME | sed -e 's/[^A-Za-z0-9._-]/_/g')
		DEFAULT_PS_PROJECT_NAME=$PS_PROJECT_NAME_PURIFIED
	else
	   echo "[⚠️] - Project name seems empty. The default name is : $DEFAULT_PS_PROJECT_NAME"
	fi

	export DEFAULT_PS_WORK_DIR="/var/www/${DEFAULT_PS_PROJECT_NAME}"
	mkdir -p $DEFAULT_PS_WORK_DIR

	if [ $? -ne 0 ]; then
		echo "[❌] - Error creating default workspace : $DEFAULT_PS_WORK_DIR" 
	else
		echo "[✅] - Creating the default workspace : $DEFAULT_PS_WORK_DIR "
	fi
}

## APACHE CONFIGURATOR
project_apache_configurator() {

	ERROR=0

	declare -a apache2_config_files=(
		"/etc/apache2/apache2.conf"
		"/etc/apache2/sites-available/000-default.conf"
		"/etc/apache2/sites-available/default-ssl.conf"
	)

	if [ -z ${DEFAULT_PS_WORK_DIR} ] || [ ! -e ${DEFAULT_PS_WORK_DIR} ]; then
		echo "[❌] - Can't config apache document root workdir var is empty : ${DEFAULT_PS_WORK_DIR}"
	else
		for config_file in "${apache2_config_files[@]}"
		do
			if [ ! -e $config_file ]; then
				echo "[⚠️] - The following apache config file not found : $config_file"
			else
				sed -i -e "s|DocumentRoot /var/www/html|DocumentRoot ${DEFAULT_PS_WORK_DIR}|g" $config_file
				if [ $? -ne 0 ];then
					echo "[❌] - Error during config apache file : $config_file"
					ERROR=1
				else
					echo "[✅] - Configure apache file: $config_file"
				fi
			fi
		done
	fi

	if [ $ERROR -eq 0 ];then
		echo "[✅] - Apache configured. Root dir : ${DEFAULT_PS_WORK_DIR}"
		echo "ServerName localhost" >> /etc/apache2/apache2.conf
	else
		echo "[⚠️] - Some files have not been configured for apache. See previous errors"
	fi
}

## GIT REPOSITORY EXTRATOR
project_git_repository_extrator() {
	
	tmp_path=tmp/tmp_repository_clone

	if [ -z $GIT_REPOSITORY ]
	then
		echo "[⚠️]  - Empty git repository." 
	else
		# Test git repository url
		git ls-remote -q $GIT_REPOSITORY &> /dev/null
		if [ $? -ne 0 ]
		then
			echo "[❌] - Remote repository not found ${GIT_REPOSITORY}.Make sure that projet exist and you have access." 
		else
			echo "[✅] - Project exists" 
			echo "[⏳] - Cloning project branch ${GIT_BRANCH}..." 
			git clone -q --single-branch --branch $GIT_BRANCH $GIT_REPOSITORY $tmp_path &> /dev/null
			chown www-data:www-data -R $tmp_path/
			rm -rf /var/www/public_html/*
			cp -rT $tmp_path $DEFAULT_PS_WORK_DIR_path/

			if [ $? -ne 0 ]
			then
				echo "[❌] - Erreur lors du copie du dépôt ${GIT_REPOSITORY} sur $DEFAULT_PS_WORK_DIR_path " 
			else
				echo "[✅] - Copy $GIT_REPOSITORY to ${DEFAULT_PS_WORK_DIR_path} " 
				echo $DEFAULT_PS_WORK_DIR_path > var/workdir_path.txt
			fi

			rm -rf $tmp_path 
		fi
	fi
}

## DATABASE CREATOR
project_database_creator() {

	logs_file=logs/setup.log

	if [ -z "$PS_DB_NAME" ] ; then
	   echo "[⚠️] - Missing DB Name. Default name : $PS_DB_NAME" 
	else
	   PS_DB_NAME=$(echo $PS_DB_NAME | sed -e 's/ /_/g')
	fi

	if [ -z "$PS_DB_SERVER" ]; then
		echo "[⚠️] - Missing MySQL server host"
	else
		RET=1
		while [ $RET -ne 0 ]; do
			echo "[⏳] - ping Database server : $PS_DB_SERVER " 
			mysql -h $PS_DB_SERVER -P $ps_db_port -u $PS_DB_USER -p$PS_DB_PASSWD -e "status" > /dev/null 2>&1
			RET=$?

			if [ $RET -ne 0 ]; then
				echo "[⏳] - Waiting for Database server confirmation ..." 
				sleep 5
			fi
		done
			echo "[✅] - Database server $PS_DB_SERVER is okay !" 

			mysql -h $PS_DB_SERVER -P $ps_db_port -u $PS_DB_USER -p$PS_DB_PASSWD -e "drop database if exists $PS_DB_NAME;" > /dev/null 2>&1

			if [ $? -ne 0 ];then
			   echo "[❌] - Error during delete database : $PS_DB_NAME " 
			else
			   echo "[✅] - Drop database : $PS_DB_NAME " 
			fi

			mysqladmin -h $PS_DB_SERVER -P $ps_db_port -u $PS_DB_USER -p$PS_DB_PASSWD create $PS_DB_NAME --force; > /dev/null 2>&1

			if [ $? -ne 0 ];then
				 echo "[❌] - Can't create database : $PS_DB_NAME " 
			else
				 echo "[✅] - Create database : $PS_DB_NAME " 
			fi
	fi
}

## PRESTASHOP INSTALL
project_prestashop_install() {
	WORK_DIR=$(cat var/workdir_path.txt)
	cd $WORK_DIR

	mkdir log app/logs
	chmod +w -R admin-dev/autoupgrade \
		app/config \
		app/logs \
		app/Resources/translations \
		cache \
		config \
		download \
		img \
		log \
		mails \
		modules \
		themes \
		translations \
		upload \
		var

	echo "[⏳] - Init composer install ..." 
	composer install > /dev/null 2>&1 ## Silent mode
	echo "[✅] - End composer install" 

	echo "[⏳] - Init make assets  ..." 
	make assets > /dev/null 2>&1 ## Silent mode
	echo "[✅] - End make assets" 

	a2enmod rewrite
	service apache2 restart


	if [ ! -z "$PS_AUTO_INSTALL" ] && [ "$PS_AUTO_INSTALL" = "1" ] ; then
	   echo "[⏳] - Init auto install ..." 

	   php install-dev/index_cli.php \
			--domain=${PS_DOMAIN}:${PS_APP_PORT} \
			--db_server=${PS_DB_SERVER} \
			--db_name=${PS_DB_NAME} \
			--db_user=${PS_DB_USER} \
			--db_password=${PS_DB_PASSWD} \
			--email=${PS_ADMIN_EMAIL} \
			--step=${PS_STEP} \
			--base_uri=${PS_BASE_URI} \
			--db_clear=${PS_DB_CLEAR} \
			--db_create=${PS_DB_CREATE} \
			--prefix=${PS_DB_PREFIX} \
			--engine=${PS_DB_ENGINE} \
			--name=${PS_SHOP_NAME} \
			--activity=${PS_SHOP_ACTIVITY} \
			--country=${PS_SHOP_COUNTRY} \
			--firstname=${PS_ADMIN_FIRSTNAME} \
			--lastname=${PS_ADMIN_LASTNAME} \
			--password=${PS_ADMIN_PASSWORD} \
			--license=${PS_LICENCE} \
			--theme=${PS_SHOP_THEME} \
			--enable_ssl=${PS_ENABLE_SSL} \
			--rewrite=${PS_REWRITE_ENGINE} \
			--fixtures=${PS_FIXTURES} 

	   rm -rf var/cache/* # Fix cache issue
	   chown -R www-data:www-data ../*
	   echo "[✅] - End installation" 
	else
	   echo "[⚠️] - Manual install" 
	fi
}

## SETUP

project_workdir_generator
project_apache_configurator
project_git_repository_extrator
project_database_creator
project_prestashop_install
