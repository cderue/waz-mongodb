#!/bin/bash
# 
# Copyright (c) Microsoft.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#



#
# setupMongoNode.sh : MongoDB Node Configuration Script by Jeff Wilcox
#
# Target Image: OpenLogic CentOS, Azure IaaS VM
#
# A specialized script specific to Microsoft Azure for configuring a 
# MongoDB cluster (without sharding, and without anything fancy 
# like RAID disks).
#
# Helps setup a primary node, join an existing cluster, or setup an
# arbiter.
#
# Optionally supports prepping, mounting and storing MongoDB data on
# an attached empty Microsoft Azure disk. This is recommended as you
# should get additional dedicated IOPS for that extra disk.
#
# Per the available Azure performance whitepapers, it is not
# recommended to use RAID configurations for increasing IOPS or 
# availability. This differs some from the standard guidance for
# using MongoDB on some other cloud providers based in the Seattle
# area, so we'll need to revisit this as more people use MongoDB
# on IaaS VMs I assume. I'm no performance expert.
#
# This script doesn't do well with error handling or restarting, so
# be sure you're ready to run it when you get going. If you need to
# try again, just delete the /etc/mongod.conf file and stop the 
# mongod service if it has run before + blow away the db data.
#
# No warranties or anything implied by this script, but I do hope
# it helps!
#

pushd /tmp > /dev/null



### PREREQ SOFTWARE

### MONGODB

# Configure mongodb.list file with the correct location
sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv EA312927
#echo "deb http://repo.mongodb.org/apt/ubuntu xenial/mongodb-org/3.2 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-3.2.list
echo "deb http://repo.mongodb.org/apt/ubuntu trusty/mongodb-org/3.2 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-3.2.list
# Disable THP
#sudo echo never > /sys/kernel/mm/transparent_hugepage/enabled
#sudo echo never > /sys/kernel/mm/transparent_hugepage/defrag
#sudo grep -q -F 'transparent_hugepage=never' /etc/default/grub || echo 'transparent_hugepage=never' >> /etc/default/grub

# Install updates
sudo apt-get -y update

# Modified tcp keepalive according to https://docs.mongodb.org/ecosystem/platforms/windows-azure/
sudo bash -c "sudo echo net.ipv4.tcp_keepalive_time = 120 >> /etc/sysctl.conf"

#Install Mongo DB
sudo apt-get install -y mongodb-org

### AZURE STORAGE CONFIG

if [ -z "$AZURE_STORAGE_ACCOUNT" ]; then
	read -p "Azure storage account name? " storageAccount
	export AZURE_STORAGE_ACCOUNT=$storageAccount
	echo
fi

if [ -z "$AZURE_STORAGE_ACCESS_KEY" ]; then
	read -p "Account access key? " storageKey
	export AZURE_STORAGE_ACCESS_KEY=$storageKey
	echo
fi

: ${AZURE_STORAGE_ACCOUNT?"Need to set AZURE_STORAGE_ACCOUNT"}
: ${AZURE_STORAGE_ACCESS_KEY?"Need to set AZURE_STORAGE_ACCESS_KEY"}

# Awesome ask function by @davejamesmiller https://gist.github.com/davejamesmiller/1965569
function ask {
    while true; do
 
        if [ "${2:-}" = "Y" ]; then
            prompt="Y/n"
            default=Y
        elif [ "${2:-}" = "N" ]; then
            prompt="y/N"
            default=N
        else
            prompt="y/n"
            default=
        fi
 
        # Ask the question
        read -p "$1 [$prompt] " REPLY
 
        # Default?
        if [ -z "$REPLY" ]; then
            REPLY=$default
        fi
 
        # Check if the reply is valid
        case "$REPLY" in
            Y*|y*) return 0 ;;
            N*|n*) return 1 ;;
        esac
 
    done
}



### VARIABLES

isPrimary=true
isArbiter=false
isUsingDataDisk=true

mongoDataPath=/var/lib/mongo

primaryPasscode=
primaryHostname="$(hostname).westeurope.cloudapp.azure.com"



### CONFIGURATION

read -p "What is the name of the replica set? (Recommended: rs0) " replicaSetName

if [ -z "$replicaSetName" ]; then
	replicaSetName=rs0
fi

read -p "What is the mongod instance port? (Default: 27017) " mongodPort

if [ -z "$mongodPort" ]; then
	mongodPort=27017
fi

replicaSetKey=$replicaSetName.key

if ! ask "Is this the first node in the replica set? "; then
	isPrimary=false

	if ask "Is this an arbiter?"; then
		isArbiter=true
		isUsingDataDisk=false
	fi

	echo
	read -p "Primary node hostname? " primaryHostname
	echo
	echo
fi

if ! $isArbiter; then
	echo You may attach an empty data disk to this VM at any time now 
	echo if you would like to utilize the extra IOPS you get in such a 
	echo scenario. Recommended for a production instance, this is not 
	echo required.
	echo
	if ! ask "Would you like to use a data disk? "; then
		isUsingDataDisk=false
	fi
fi

if $isPrimary; then
	echo
	echo This primary VM has the hostname $primaryHostname - that will 
	echo be needed to bring online new nodes in the cluster.
	echo

	echo Time to set a password for the 'clusteradmin' user. This user will not 
	echo directly have access to data stored in the cluster, but it will be able
	echo to create and modify such credentials.
	echo
	

	read -s -p "Please enter a new password for the 'clusteradmin' MongoDB user: " primaryPasscode
	echo
	read -s -p "Please confirm that awesome new password: " primaryPasscodeConfirmation
	echo

	if [ "$primaryPasscode" != "$primaryPasscodeConfirmation" ]; then
		echo The passwords did not match. Sorry. Goodbye.
		exit 1
	fi

fi

echo
echo MongoDB VM will be configured as:

echo - Replica set named $replicaSetName

if $isPrimary; then
	echo - Primary node in the replica set
	echo - New 'clusteradmin' user with a password you set.
fi

if $isArbiter; then
	echo - Replica set arbiter
	echo
	echo DISK NOTE:
	echo There is no need to attach a data disk to this VM.
fi

if ! $isPrimary && ! $isArbiter ; then
	echo - Additional node in the replica set
fi

if $isUsingDataDisk; then
	echo - Additional data disk that will mount to /mnt/data
fi

echo
echo
echo OK. Please sit back, relax, and enjoy the show...
echo



### DATA DISK

if $isUsingDataDisk; then

	mongoDataPath=/mnt/data

	echo Checking for attached Azure data disk...
	while [ ! -e /dev/sdc ]; do echo waiting for /dev/sdc empty disk to attach; sleep 20; done

	echo Partitioning...
	sudo fdisk /dev/sdc <<ENDPARTITION > /tmp/fdisk.log 2>&1
n
p
1


w
ENDPARTITION

	echo Formatting w/ext4...
	sudo mkfs -t ext4 /dev/sdc1  > /tmp/format.log 2>&1

	echo Preparing permanent data disk mount point at /mnt/data...
	sudo mkdir /mnt/data
	

	echo Mounting the new disk...
	# sudo mount /dev/sdc1 /datadrive
	sudo mount /dev/sdc1 /mnt/data
	#sudo e2label /dev/sdc1 /mnt/data
	echo Add a new entry to fstab
        echo '/dev/sdc1 /mnt/data ext4 defaults,auto,noatime,nodiratime,noexec 0 0' | sudo tee -a /etc/fstab
fi



### MONGODB

echo Creating MongoDB folders on the disk owned by the mongod user in $mongoDataPath...
sudo mkdir $mongoDataPath/log
sudo mkdir $mongoDataPath/db
sudo chown -R mongodb:mongodb $mongoDataPath

# FYI: YAML syntax introduced in MongoDB 2.6
echo Configuring MongoDB...
#sudo tee /etc/mongod.conf > /dev/null <<EOF
#systemLog:
#    destination: file
#    path: "/var/log/mongodb/mongod.log"
#    quiet: true
#    logAppend: true
#processManagement:
#    fork: true
#net:
#    port: $mongodPort
#storage:
#    dbPath: "$mongoDataPath/db"
#    directoryPerDB: true
#    journal:
#        enabled: true
#replication:
#    replSetName: "$replicaSetName"
#EOF

echo Installing replica set key on the machine...

sudo apt-get install cifs-utils
sudo mkdir /mnt/mountpoint
sudo mount -t cifs //powerzeevault.file.core.windows.net/keyfiles /mnt/mountpoint -o vers=3.0,username=$storageAccount,password=$storageKey,dir_mode=0777,file_mode=0777
 
if $isPrimary; then
	echo Generating replica set security key...
	openssl rand -base64 753 > $replicaSetKey
	echo Securely storing replica set key in Azure storage...
	cp $replicaSetKey /mnt/mountpoint/$replicaSetKey
else
	echo Acquiring replica set security key from the cloud...
	cp /mnt/mountpoint/$replicaSetKey ./$replicaSetKey
fi

sudo chown mongodb:mongodb $replicaSetKey
sudo chmod 0600 $replicaSetKey
sudo mv $replicaSetKey /etc/$replicaSetKey

echo
echo About to bring online MongoDB.
echo This may take a few minutes as the initial journal is preallocated.
echo

echo Initializing the replica set...

	sleep 2

	cat <<EOF > /tmp/initializeReplicaSetPrimary.js
rsconfig = {_id: "$replicaSetName",members:[{_id:0,host:"$primaryHostname:$mongodPort"}]}
rs.initiate(rsconfig);
rs.conf();
EOF

	/usr/bin/mongo /tmp/initializeReplicaSetPrimary.js > /tmp/creatingMongoCluster.log 2>&1

	sleep 10
	
	echo Creating cluster administrator account...
	cat <<EOF > /tmp/initializeAuthentication.js
db = db.getSiblingDB('admin');
db.createUser({
  user: 'clusteradmin',
  pwd: '$primaryPasscode',
  roles: [
    'userAdminAnyDatabase',
    'clusterAdmin',
    { db: 'config', role: 'readWrite' },
    { db: 'local', role: 'read' }
  ]
});
EOF
	sudo /usr/bin/mongod --fork --logpath "/var/log/mongodb/mongodb.log" --dbpath "$mongoDataPath/db"
	/usr/bin/mongo /tmp/initializeAuthentication.js --verbose > /tmp/creatingMongoClusterAdmin.log 2>&1	

	echo Authentication ready. Restarting MongoDB...
	#sudo service mongod restart

	# remove credentials trace
	rm /tmp/initializeAuthentication.js

echo Stopping MongoDB service...
sudo service mongod stop
echo Starting MongoDB service...
sudo /usr/bin/mongod --fork --auth --logpath "/var/log/mongodb/mongodb.log" --dbpath "$mongoDataPath/db"
sudo service mongod stop
sudo /usr/bin/mongod --fork --keyFile "/etc/$replicaSetKey" --logpath "/var/log/mongodb/mongodb.log" --dbpath "$mongoDataPath/db"
sudo apt-get install -y sysv-rc-conf
sudo sysv-rc-conf mongod on

if $isPrimary; then

	


	if ask "Would you like to connect to MongoDB Shell now ? "; then
		/usr/bin/mongo admin -uclusteradmin -p$primaryPasscode
	fi

else

	ourHostname="$(hostname).westeurope.cloudapp.azure.com"

	if $isArbiter; then
		cat <<EOF > /tmp/joinCluster.js
rs.addArb('$ourHostname:$mongodPort');
rs.conf();
rs.status();
EOF

	else

		cat <<EOF > /tmp/joinCluster.js
rs.add('$ourHostname:$mongodPort');
rs.conf();
rs.status();
EOF

	fi

	echo Joining the MongoDB cluster...
	/usr/bin/mongo $primaryHostname/test  /tmp/joinCluster.js --verbose > /tmp/joinCluster.log 2>&1

	if ask "Would you like to view the replica set status? "; then
		/usr/bin/mongo $primaryHostname/test << EOF
rs.status();
EOF
	fi

	if ask "Would you like to connect to the primary node to look around? "; then
		/usr/bin/mongo $primaryHostname/test
	fi

fi

echo
echo Well, that looks like a wrap. Have a nice day!
echo

popd > /dev/null
