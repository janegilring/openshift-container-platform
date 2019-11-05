#!/bin/bash
echo $(date) " - Starting Infra / Node Prep Script"

export USERNAME_ORG=$1
export PASSWORD_ACT_KEY="$2"
export POOL_ID=$3

# Remove RHUI

rm -f /etc/yum.repos.d/rh-cloud.repo
sleep 10

# Register Host with Cloud Access Subscription
echo $(date) " - Register host with Cloud Access Subscription"

subscription-manager register --force --username="$USERNAME_ORG" --password="$PASSWORD_ACT_KEY" || subscription-manager register --force --activationkey="$PASSWORD_ACT_KEY" --org="$USERNAME_ORG"
RETCODE=$?

if [ $RETCODE -eq 0 ]
then
    echo "Subscribed successfully"
elif [ $RETCODE -eq 64 ]
then
    echo "This system is already registered."
else
    sleep 5
	subscription-manager register --force --username="$USERNAME_ORG" --password="$PASSWORD_ACT_KEY" || subscription-manager register --force --activationkey="$PASSWORD_ACT_KEY" --org="$USERNAME_ORG"
	RETCODE2=$?
	if [ $RETCODE2 -eq 0 ]
	then
		echo "Subscribed successfully"
	elif [ $RETCODE2 -eq 64 ]
	then
		echo "This system is already registered."
	else
		echo "Incorrect Username / Password or Organization ID / Activation Key specified. Unregistering system from RHSM"
		subscription-manager unregister
		exit 3
	fi
fi

subscription-manager attach --pool=$POOL_ID > attach.log
if [ $? -eq 0 ]
then
    echo "Pool attached successfully"
else
    grep attached attach.log
    if [ $? -eq 0 ]
    then
        echo "Pool $POOL_ID was already attached and was not attached again."
    else
        echo "Incorrect Pool ID or no entitlements available"
        exit 4
    fi
fi

# Disable all repositories and enable only the required ones
echo $(date) " - Disabling all repositories and enabling only the required repos"

subscription-manager repos --disable="*"

subscription-manager repos \
    --enable="rhel-7-server-rpms" \
    --enable="rhel-7-server-extras-rpms" \
    --enable="rhel-7-server-ose-3.11-rpms" \
    --enable="rhel-7-server-ansible-2.6-rpms" \
    --enable="rhel-7-fast-datapath-rpms" \
    --enable="rh-gluster-3-client-for-rhel-7-server-rpms" \
    --enable="rhel-7-server-optional-rpms"

# Install base packages and update system to latest packages
echo $(date) " - Install base packages and update system to latest packages"

yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion kexec-tools sos psacct ansible
yum -y install cloud-utils-growpart.noarch
yum -y update glusterfs-fuse
yum -y update --exclude=WALinuxAgent
echo $(date) " - Base package insallation and updates complete"

# Grow Root File System
echo $(date) " - Grow Root FS"

rootdev=`findmnt --target / -o SOURCE -n`
rootdrivename=`lsblk -no pkname $rootdev`
rootdrive="/dev/"$rootdrivename
name=`lsblk  $rootdev -o NAME | tail -1`
part_number=${name#*${rootdrivename}}

growpart $rootdrive $part_number -u on
xfs_growfs $rootdev

if [ $? -eq 0 ]
then
    echo "Root partition expanded"
else
    echo "Root partition failed to expand"
    exit 6
fi

# Install Docker
echo $(date) " - Installing Docker"
yum -y install docker

# Update docker config for insecure registry
echo "
# Adding insecure-registry option required by OpenShift
OPTIONS=\"\$OPTIONS --insecure-registry 172.30.0.0/16\"
" >> /etc/sysconfig/docker

# Create thin pool logical volume for Docker
echo $(date) " - Creating thin pool logical volume for Docker and staring service"

DOCKERVG=$( parted -m /dev/sda print all 2>/dev/null | grep unknown | grep /dev/sd | cut -d':' -f1 | head -n1 )

echo "
# Adding OpenShift data disk for docker
DEVS=${DOCKERVG}
VG=docker-vg
" >> /etc/sysconfig/docker-storage-setup

# Running setup for docker storage
docker-storage-setup
if [ $? -eq 0 ]
then
    echo "Docker thin pool logical volume created successfully"
else
    echo "Error creating logical volume for Docker"
    exit 5
fi

# Enable and start Docker services

systemctl enable docker
systemctl start docker

# Resizing for LVM disks for LVM RHEL OS

DEVICE="/dev/sda"
PARTNR="2"
APPLY="apply"

echo "Before fdisk"

fdisk -l $DEVICE$PARTNR >> /dev/null 2>&1 || (echo "could not find device $DEVICE$PARTNR - please check the name" && exit 1)

echo "After fdisk"

CURRENTSIZEB=`fdisk -l $DEVICE$PARTNR | grep "Disk $DEVICE$PARTNR" | cut -d' ' -f5`
CURRENTSIZE=`expr $CURRENTSIZEB / 1024 / 1024`

# So get the disk-informations of our device in question
# .. to ensure the units are displayed as MB, since otherwise it will vary by disk size ( MB, G, T )

MAXSIZEMB=`printf %s\\n 'unit MB print list' | parted | grep "Disk ${DEVICE}" | cut -d' ' -f3 | tr -d MB`

echo "[ok] would/will resize to from ${CURRENTSIZE}MB to ${MAXSIZEMB}MB "

echo "[ok] applying resize operation.."
parted ${DEVICE} resizepart ${PARTNR} ${MAXSIZEMB}
echo "[done]"

lvextend -l +100%FREE /dev/rootvg/varlv
xfs_growfs /dev/rootvg/varlv

echo "[extended lv]"

#END OF DISK re-size

# ICP41 Prerequistes - SYSTEM V IPC params
sudo sysctl -w vm.max_map_count=1048576
echo "vm.max_map_count=1048576" | sudo tee -a /etc/sysctl.conf

echo "-A OS_FIREWALL_ALLOW -p tcp -m state --state NEW -m tcp --dport 44134 -j ACCEPT" | sudo tee -a /etc/sysconfig/iptables

echo $(date) " - Script Complete"
