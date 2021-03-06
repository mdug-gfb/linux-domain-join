#!/bin/sh
# Copyright 2020 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not
# use this file except in compliance with the License. A copy of the
# License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "license" file accompanying this file. This file is distributed
# on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
# either express or implied. See the License for the specific language governing
# permissions and limitations under the License.
DIRECTORY_ID=""
DIRECTORY_NAME=""
DIRECTORY_OU=""
REALM=""
DNS_IP_ADDRESS1=""
DNS_IP_ADDRESS2=""
LINUX_DISTRO=""
CURTIME=""
REGION=""
EFSSERVER=""
ADDOCKERGROUP=""
# https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-linux.html
AWSCLI="/usr/local/bin/aws"
# Service Creds from Secrets Manager
DOMAIN_USERNAME=""
DOMAIN_PASSWORD=""
HOSTNAME_PREFIX=""
##################################################
## Set hostname to NETBIOS computer name #########
##################################################
set_hostname() {
    INSTANCE_NAME=$(hostname --short) 2>/dev/null
    echo "Current hostname : $INSTANCE_NAME"
    # NetBIOS computer names consist of up to 15 bytes of OEM characters
    # https://docs.microsoft.com/en-us/windows/win32/sysinfo/computer-names?redirectedfrom=MSDN
    # Naming conventions in Active Directory
    # https://support.microsoft.com/en-us/help/909264/naming-conventions-in-active-directory-for-computers-domains-sites-and
    PRIINT=$(route | grep '^default' | grep -o '[^ ]*$')
    echo "Primary Interface $PRIINT"
    SUFFIX=$(ip addr show $PRIINT |grep $PRIINT$ |cut -f1 -d/ |cut -f3- -d. |sed "s/\./-/g")
    echo $HOSTNAME_PREFIX
    echo $SUFFIX
    COMPUTER_NAME=$(echo $HOSTNAME_PREFIX-$SUFFIX| tr '[:lower:]' '[:upper:]')
    echo "Setting hostname to $COMPUTER_NAME"
    HOSTNAMECTL=$(which hostnamectl)
    if [ ! -z "$HOSTNAMECTL" ]; then
        hostnamectl set-hostname $COMPUTER_NAME.$DIRECTORY_NAME >/dev/null
    else
        hostname $COMPUTER_NAME.$DIRECTORY_NAME >/dev/null
    fi
    if [ $? -ne 0 ]; then echo "***Failed: set_hostname(): set hostname failed" && exit 1; fi
    # https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-hostname.html
    if [ -f /etc/sysconfig/network ]; then
            sed -i "s/HOSTNAME=.*$//g" /etc/sysconfig/network
        echo "HOSTNAME=$COMPUTER_NAME.$DIRECTORY_NAME" >> /etc/sysconfig/network
    fi
}
##################################################
## Get Region from Instance Metadata #############
##################################################
get_region() {
    REGION=$(curl http://169.254.169.254/latest/dynamic/instance-identity/document 2>/dev/null | grep region | awk -F: '{ print $2 }' | tr -d '\", ')
}
##################################################
########## Install components ####################
##################################################
install_components() {
    LINUX_DISTRO=$(cat /etc/os-release | grep NAME | awk -F'=' '{print $2}')
    LINUX_DISTRO_VERSION_ID=$(cat /etc/os-release | grep VERSION_ID | awk -F'=' '{print $2}' | tr -d '"')
    if [ -z $LINUX_DISTRO_VERSION_ID ]; then
       echo "**Failed : Unsupported OS version $LINUX_DISTRO : $LINUX_DISTRO_VERSION_ID"
       exit 1
    fi
    if grep 'CentOS' /etc/os-release 1>/dev/null 2>/dev/null; then
        if [ "$LINUX_DISTRO_VERSION_ID" -lt "7" ] ; then
            echo "**Failed : Unsupported OS version $LINUX_DISTRO : $LINUX_DISTRO_VERSION_ID"
            exit 1
        fi
        LINUX_DISTRO='CentOS'
        # yum -y update
        ## yum update takes too long
        yum -y install jq realmd adcli oddjob-mkhomedir oddjob sssd samba-common-tools autofs docker krb5-workstation unzip >/dev/null
        if [ $? -ne 0 ]; then echo "install_components(): yum install errors for CentOS" && return 1; fi
    elif grep -e 'Red Hat' /etc/os-release 1>/dev/null 2>/dev/null; then
        LINUX_DISTRO='RHEL'
        RHEL_MAJOR_VERSION=$(echo $LINUX_DISTRO_VERSION_ID | awk -F'.' '{print $1}')
        RHEL_MINOR_VERSION=$(echo $LINUX_DISTRO_VERSION_ID | awk -F'.' '{print $2}')
        if [ $RHEL_MAJOR_VERSION -eq "7" ] && [ ! -z $RHEL_MINOR_VERSION ] && [ $RHEL_MINOR_VERSION -lt "6" ]; then
            # RHEL 7.5 and below are not supported
            echo "**Failed : Unsupported OS version $LINUX_DISTRO : $LINUX_DISTRO_VERSION_ID"
            exit 1
        fi
        if [ $RHEL_MAJOR_VERSION -eq "7" ] && [ -z $RHEL_MINOR_VERSION ]; then
            # RHEL 7 is not supported
            echo "**Failed : Unsupported OS version $LINUX_DISTRO : $LINUX_DISTRO_VERSION_ID"
            exit 1
        fi
        # yum -y update
        ## yum update takes too long
        # https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html-single/deploying_different_types_of_servers/index
        yum -y  install jq realmd adcli oddjob-mkhomedir oddjob sssd samba-common-tools autofs docker krb5-workstation python3 vim unzip >/dev/null
        alias python=python3
        if [ $? -ne 0 ]; then echo "install_components(): yum install errors for Red Hat" && return 1; fi
        systemctl restart dbus
    elif grep -e 'Fedora' /etc/os-release 1>/dev/null 2>/dev/null; then
        LINUX_DISTRO='Fedora'
        ## yum update takes too long, but it is unavoidable here.
        yum -y update
        yum -y  install jq realmd adcli oddjob-mkhomedir oddjob sssd samba-common-tools autofs docker krb5-workstation python3 vim unzip >/dev/null
        alias python=python3
        if [ $? -ne 0 ]; then echo "install_components(): yum install errors for Fedora" && return 1; fi
        systemctl restart dbus
    elif grep 'Amazon Linux' /etc/os-release 1>/dev/null 2>/dev/null; then
         LINUX_DISTRO='AMAZON_LINUX'
         # yum -y update
         ## yum update takes too long
         yum -y  install jq realmd adcli oddjob-mkhomedir oddjob sssd samba-common-tools autofs docker krb5-workstation unzip  >/dev/null
         if [ $? -ne 0 ]; then echo "install_components(): yum install errors for Amazon Linux" && return 1; fi
    elif grep 'Ubuntu' /etc/os-release 1>/dev/null 2>/dev/null; then
         LINUX_DISTRO='UBUNTU'
         UBUNTU_MAJOR_VERSION=$(echo $LINUX_DISTRO_VERSION_ID | awk -F'.' '{print $1}')
         UBUNTU_MINOR_VERSION=$(echo $LINUX_DISTRO_VERSION_ID | awk -F'.' '{print $2}')
         if [ $UBUNTU_MAJOR_VERSION -lt "14" ]; then
            # Ubuntu versions below 14.04 are not supported
            echo "**Failed : Unsupported OS version $LINUX_DISTRO : $LINUX_DISTRO_VERSION_ID"
            exit 1
         fi
         # set DEBIAN_FRONTEND variable to noninteractive to skip any interactive post-install configuration steps.
         export DEBIAN_FRONTEND=noninteractive
         apt-get -y update
         if [ $? -ne 0 ]; then echo "install_components(): apt-get update errors for Ubuntu" && return 1; fi
         apt-get -yq install jq realmd adcli winbind samba libnss-winbind libpam-winbind libpam-krb5 krb5-config krb5-locales krb5-user packagekit  ntp unzip python > /dev/null
         if [ $? -ne 0 ]; then echo "install_components(): apt-get install errors for Ubuntu" && return 1; fi
         # Disable Reverse DNS resolution. Ubuntu Instances must be reverse-resolvable in DNS before the realm will work.
         sed -i "s/default_realm.*$/default_realm = $REALM\n\trdns = false/g" /etc/krb5.conf
         if [ $? -ne 0 ]; then echo "install_components(): access errors to /etc/krb5.conf"; return 1; fi
         if ! grep "Ubuntu 16.04" /etc/os-release 2>/dev/null; then
             pam-auth-update --enable mkhomedir
         fi
    elif grep 'SUSE Linux' /etc/os-release 1>/dev/null 2>/dev/null; then
         SUSE_MAJOR_VERSION=$(echo $LINUX_DISTRO_VERSION_ID | awk -F'.' '{print $1}')
         SUSE_MINOR_VERSION=$(echo $LINUX_DISTRO_VERSION_ID | awk -F'.' '{print $2}')
         if [ "$SUSE_MAJOR_VERSION" -lt "15" ]; then
            echo "**Failed : Unsupported OS version $LINUX_DISTRO : $LINUX_DISTRO_VERSION_ID"
            exit 1
         fi
         if [ "$SUSE_MAJOR_VERSION" -eq "15" ]; then
            sudo SUSEConnect -p PackageHub/15.1/x86_64
         fi
         LINUX_DISTRO='SUSE'
         sudo zypper update -y
         sudo zypper -n install jq realmd adcli sssd sssd-tools sssd-ad samba-client krb5-client samba-winbind krb5-client python
         if [ $? -ne 0 ]; then
            return 1
         fi
         alias python=python3
    elif grep 'Debian' /etc/os-release; then
         DEBIAN_MAJOR_VERSION=$(echo $LINUX_DISTRO_VERSION_ID | awk -F'.' '{print $1}')
         DEBIAN_MINOR_VERSION=$(echo $LINUX_DISTRO_VERSION_ID | awk -F'.' '{print $2}')
         if [ "$DEBIAN_MAJOR_VERSION" -lt "9" ]; then
            echo "**Failed : Unsupported OS version $LINUX_DISTRO : $LINUX_DISTRO_VERSION_ID"
            exit 1
         fi
         apt-get -y update
         LINUX_DISTRO='DEBIAN'
         DEBIAN_FRONTEND=noninteractive apt-get -yq install jq realmd adcli winbind samba libnss-winbind libpam-winbind libpam-krb5 krb5-config krb5-locales krb5-user packagekit  ntp unzip > /dev/null
         if [ $? -ne 0 ]; then
            return 1
         fi
    fi
    if uname -a | grep -e "x86_64" -e "amd64"; then
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
        if [ $? -ne 0 ]; then
                curl -1 "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
                if [ $? -ne 0 ]; then
                    echo "***Failed: install_components curl -1 https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip failed." && exit 1
                fi
        fi
    elif uname -a | grep "aarch64"; then
        curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "/tmp/awscliv2.zip"
        if [ $? -ne 0 ]; then
                curl -1 "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "/tmp/awscliv2.zip"
                if [ $? -ne 0 ]; then
                    echo "***Failed: install_components curl -1 https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip failed." && exit 1
                fi
        fi
    else
        echo "***Failed: install_components processor type is unsupported." && exit 1
    fi
    cd /tmp
    unzip -o awscliv2.zip 1>/dev/null
    ./aws/install -u 1>/dev/null
    if [ $? -ne 0 ]; then echo "***Failed: aws cli install" && exit 1; fi
    cd -
    return 0
}
####################################################
#### Retrieve Service Account Credentials and ######
#### other parameters from Secrets Manager    ######
####################################################
get_serviceparams() {
    SECRET_ID="ec2/linux/domainJoin"
    secret=$(/usr/local/bin/aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --region $REGION \
              --query SecretString --output text 2>/dev/null)
    DOMAIN_USERNAME=$(echo $secret | jq -r '."directory-join-user"')
    DOMAIN_PASSWORD=$(echo $secret | jq -r '."directory-join-password"')
    DIRECTORY_NAME=$(echo $secret | jq -r '."directory-name"')
    DIRECTORY_ID=$(echo $secret | jq -r '."directory-id"')
    DIRECTORY_OU=$(echo $secret | jq -r '."directory-ou"')
    EFSSERVER=$(echo $secret | jq -r '."efsserver"')
    ADDOCKERGROUP=$(echo $secret | jq -r '."dockergroup"')
    HOSTNAME_PREFIX=$(echo $secret | jq -r '.hostnameprefix')
}
##################################################
## Setup resolv.conf and also dhclient.conf ######
## to prevent overwriting of resolv.conf    ######
##################################################
setup_resolv_conf_and_dhclient_conf() {
    if [ ! -z "$DNS_IP_ADDRESS1" ] && [ ! -z "$DNS_IP_ADDRESS2" ]; then
        touch /etc/resolv.conf
        mv /etc/resolv.conf /etc/resolv.conf.backup."$CURTIME"
        echo ";Generated by Domain Join SSMDocument" > /etc/resolv.conf
        echo "search $DIRECTORY_NAME" >> /etc/resolv.conf
        echo "nameserver $DNS_IP_ADDRESS1" >> /etc/resolv.conf
        echo "nameserver $DNS_IP_ADDRESS2" >> /etc/resolv.conf
        touch /etc/dhcp/dhclient.conf
        mv /etc/dhcp/dhclient.conf /etc/dhcp/dhclient.conf.backup."$CURTIME"
        echo "supersede domain-name-servers $DNS_IP_ADDRESS1, $DNS_IP_ADDRESS2;" > /etc/dhcp/dhclient.conf
    elif [ ! -z "$DNS_IP_ADDRESS1" ] && [ -z "$DNS_IP_ADDRESS2" ]; then
        touch /etc/resolv.conf
        mv /etc/resolv.conf /etc/resolv.conf.backup."$CURTIME"
        echo ";Generated by Domain Join SSMDocument" > /etc/resolv.conf
        echo "search $DIRECTORY_NAME" >> /etc/resolv.conf
        echo "nameserver $DNS_IP_ADDRESS1" >> /etc/resolv.conf
        touch /etc/dhcp/dhclient.conf
        mv /etc/dhcp/dhclient.conf /etc/dhcp/dhclient.conf.backup."$CURTIME"
        echo "supersede domain-name-servers $DNS_IP_ADDRESS1;" > /etc/dhcp/dhclient.conf
    elif [ -z "$DNS_IP_ADDRESS1" ] && [ ! -z "$DNS_IP_ADDRESS2" ]; then
        touch /etc/resolv.conf
        mv /etc/resolv.conf /etc/resolv.conf.backup."$CURTIME"
        echo ";Generated by Domain Join SSMDocument" > /etc/resolv.conf
        echo "search $DIRECTORY_NAME" >> /etc/resolv.conf
        echo "nameserver $DNS_IP_ADDRESS2" >> /etc/resolv.conf
        touch /etc/dhcp/dhclient.conf
        mv /etc/dhcp/dhclient.conf /etc/dhcp/dhclient.conf.backup."$CURTIME"
        echo "supersede domain-name-servers $DNS_IP_ADDRESS2;" > /etc/dhcp/dhclient.conf
    else
        echo "***Failed: No DNS IPs available" && exit 1
    fi
}
##################################################
## Set PEER_DNS to yes ###########################
##################################################
set_peer_dns() {
    for f in $(ls /etc/sysconfig/network-scripts/ifcfg-*)
    do
        if echo $f | grep "lo"; then
            continue
        fi
        if ! grep PEERDNS $f; then
            echo "" >> $f
            echo PEERDNS=yes >> $f
        fi
    done
}
##################################################
## Print shell variables #########################
##################################################
print_vars() {
    echo "REGION = $REGION"
    echo "DIRECTORY_ID = $DIRECTORY_ID"
    echo "DIRECTORY_NAME = $DIRECTORY_NAME"
    echo "DIRECTORY_OU = $DIRECTORY_OU"
    echo "REALM = $REALM"
    echo "DNS_IP_ADDRESS1 = $DNS_IP_ADDRESS1"
    echo "DNS_IP_ADDRESS2 = $DNS_IP_ADDRESS2"
    echo "COMPUTER_NAME = $COMPUTER_NAME"
    echo "hostname = $(hostname)"
    echo "LINUX_DISTRO = $LINUX_DISTRO"
    echo "EFSSERVER = $EFSSERVER"
    echo "ADDOCKERGROUP = $ADDOCKERGROUP"
}
#########################################################
## Add FQDN and Hostname to Hosts file for below error ##
# No DNS domain configured for ip-172-31-12-23.         #
# Unable to perform DNS Update.                         #
#########################################################
configure_hosts_file() {
    fullhost="${COMPUTER_NAME}.${DIRECTORY_NAME}"  # ,, means lowercase since bash v4
    ip_address="$(ip -o -4 addr show eth0 | awk '{print $4}' | cut -d/ -f1)"
    cleanup_comment='# Generated by Domain Join SSMDocument'
    sed -i".orig" -r\
        "/^.*${cleanup_comment}/d;\
        /^127.0.0.1\s+localhost\s*/a\\${ip_address} ${fullhost} ${COMPUTER_NAME} ${cleanup_comment}" /etc/hosts
}
##################################################
## Add AWS Directory Service DNS IP Addresses as #
## primary to the resolv.conf and dhclient       #
## configuration files.                          #
##################################################
do_dns_config() {
    setup_resolv_conf_and_dhclient_conf
    if [ $LINUX_DISTRO = 'AMAZON_LINUX' ]; then
        set_peer_dns
    fi
    if [ $LINUX_DISTRO = "UBUNTU" ]; then
        if [ -d /etc/netplan ]; then
            # Ubuntu 18.04
            cat << EOF | tee /etc/netplan/99-custom-dns.yaml
network:
    version: 2
    ethernets:
        eth0:
            nameservers:
                addresses: [$DNS_IP_ADDRESS1, $DNS_IP_ADDRESS2]
            dhcp4-overrides:
                use-dns: false
EOF
            netplan apply
            if [ $? -ne 0 ]; then echo "***Failed: do_dns_config(): netplan apply failed" && exit 1; fi
            # Seems to fail otherwise
            sleep 15
        fi
    fi
    if [ $LINUX_DISTRO = "RHEL" ] || [ $LINUX_DISTRO = "Fedora" ]; then
        set_peer_dns
        if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
            cp /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/NetworkManager.conf."$CURTIME"
            cat /etc/NetworkManager/NetworkManager.conf."$CURTIME" | sed "s/\[main\]/[main]\ndns=none/g" > /etc/NetworkManager/NetworkManager.conf
        fi
    fi
    if [ $LINUX_DISTRO = "CentOS" ]; then
        set_peer_dns
    fi
}
##################################################
## DNS IP reachability test to                  ##
## catch invalid or unreachable DNS IPs         ##
##################################################
is_dns_ip_reachable() {
    DNS_IP="$1"
    ping -c 1 "$DNS_IP" 1>/dev/null 2>/dev/null
    if [ $? -eq 0 ]; then
            return 0
    fi
    return 1
}
##################################################
## DNS may already be reachable if DHCP option  ##
## sets are used.                               ##
##################################################
is_directory_reachable() {
    MAX_RETRIES=5
    for i in $(seq 1 $MAX_RETRIES)
    do
        ping -c 1 "$DIRECTORY_NAME" 2>/dev/null
        if [ $? -eq 0 ]; then
            return 0
        fi
    done
    return 1
}
##################################################
## Join Linux instance to AWS Directory Service ##
##################################################
do_domainjoin() {
    MAX_RETRIES=10
    for i in $(seq 1 $MAX_RETRIES)
    do
	echo "[$i] Attempting to join domain"
        if [ -z "$DIRECTORY_OU" ]; then
            LOG_MSG=$(echo $DOMAIN_PASSWORD | realm join --client-software=sssd -U ${DOMAIN_USERNAME}@${DIRECTORY_NAME} "$DIRECTORY_NAME" -v 2>&1)
        else
            LOG_MSG=$(echo $DOMAIN_PASSWORD | realm join --client-software=sssd -U ${DOMAIN_USERNAME}@${DIRECTORY_NAME} "$DIRECTORY_NAME" --computer-ou="$DIRECTORY_OU" -v 2>&1)
        fi
        STATUS=$?
        if [ $STATUS -eq 0 ]; then
            break
        else
            if echo "$LOG_MSG" | grep -q "Already joined to this domain"; then
                echo "do_domainjoin(): Already joined to this domain : $LOG_MSG"
                STATUS=0
                break
            fi
        fi
        sleep 10
    done
    if [ $STATUS -ne 0 ]; then
        echo "***Failed: realm join failed" && exit 1
    fi
    echo "########## SUCCESS: realm join successful $LOG_MSG ##########"
}
##############################
## Configure nsswitch.conf  ##
##############################
config_nsswitch() {
    # Edit nsswitch config
    NSSWITCH_CONF_FILE=/etc/nsswitch.conf
    sed -i 's/^\s*passwd:.*$/passwd:     compat sss/' $NSSWITCH_CONF_FILE
    sed -i 's/^\s*group:.*$/group:      compat sss/' $NSSWITCH_CONF_FILE
    sed -i 's/^\s*shadow:.*$/shadow:     compat sss/' $NSSWITCH_CONF_FILE
}
##################################################################
## Mark Duggan - January 2021                                   ##
## Configure sssd to use ids, homedir and ssh keys stored in AD ##
##################################################################

config_sssd() {
	echo "Configuring SSSD"
	sed -i 's/services = nss, pam/services = nss, pam, ssh/g' /etc/sssd/sssd.conf
	# disabling ldap_id_mapping as we have UIDs set in AD
	sed -i 's/ldap_id_mapping = True/ldap_id_mapping = False/g' /etc/sssd/sssd.conf
	# use short name, without needing domain name
	sed -i 's/use_fully_qualified_names = True/use_fully_qualified_names = False/g' /etc/sssd/sssd.conf
	# remove domain name from fallback_homedir too
	sed -i 's/fallback_homedir = \/home\/%u@%d/fallback_homedir = \/home\/%u/g' /etc/sssd/sssd.conf
	# add auto creation of private groups and specificying the AD attribute to lookup for public keys
	sed -i '$ a auto_private_groups = true\nldap_user_ssh_public_key = sshPublicKeys' /etc/sssd/sssd.conf
	# Allow UID/GID below 1000. 
	sed -i 's/ID_MIN                  1000/ID_MIN                  500/g' /etc/login.defs
	# Modify sshd_config to allow password auth, and to use SSSD to query AD for public kets
	sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
	sed -i 's/AuthorizedKeysCommand \/opt\/aws\/bin\/eic_run_authorized_keys %u %f/AuthorizedKeysCommand \/usr\/bin\/sss_ssh_authorizedkeys/g' /etc/ssh/sshd_config
	sed -i 's/AuthorizedKeysCommandUser ec2-instance-connect/AuthorizedKeysCommandUser root/g' /etc/ssh/sshd_config
	authconfig --updateall
        systemctl restart sshd.service
        systemctl restart sssd.service
}
config_autofs(){
	echo "Configuring AutoFS"
 	sed -i	'$ a \/mnt\/nfs\/ \/etc\/auto.home --timeout=300' /etc/auto.master
	echo "home -nfs4,rw,soft,timeo=5,intr $EFSSERVER:/" > /etc/auto.home
	systemctl enable autofs.service
	systemctl start autofs.service
}
config_docker(){
	echo "Configuring Docker for group $ADDOCKERGROUP"
	# Get GID of Docker Group in AD
	DOCKERGID=$(getent group docker | cut -f3 -d:)
	ADDOCKERGID=""
	MAX_RETRIES=10
	DOCKERSOCK=/var/run/docker.sock
        for i in $(seq 1 $MAX_RETRIES)
	do
		echo -n "[$i] Attempting to contact domain $DIRECTORY_NAME"
		SSSDHOST=$(getent hosts $DIRECTORY_NAME |head -n1)
		if [ -z "$SSSDHOST" ]
		then
			echo "Could not contact $DIRECTORY_NAME."
			if [ $i -lt $MAX_RETRIES ]
			then
				echo " Retrying"
			else
				echo " Giving Up"
			fi
		else
			echo
			echo "Contacted $DIRECTORY_NAME. Host $SSSDHOST. Getting Docker Group"
		        ADDOCKERGID=$(getent group $ADDOCKERGROUP | cut -f3 -d:)
			echo "AD Docker GID: $ADDOCKERGID"
			break
		fi
	done
	if [ ! -z $ADDOCKERGID ]
	then
		echo "Local Docker GID = $DOCKERGID"
		echo "AD Docker GID = $ADDOCKERGID"
		echo "Setting docker GID to $ADDOCKERGID"
		# Stop SSSD to allow groupmod to set GID to match
		if [ -z $DOCKERGID ]
		then
			echo "Docker group doesn't exist. Creating"
			groupadd -g $ADDOCKERGID docker
		else
			echo "Stopping SSSD and invalidating cache to allow GID match"
			systemctl stop sssd.service > /dev/null  2>&1
			sss_cache -E
			groupmod -g $ADDOCKERGID docker
		fi
		if [ -S $DOCKERSOCK ]
		then
			echo "Changing group for $DOCKERSOCK"
			chgrp docker $DOCKERSOCK
		fi
		systemctl enable docker.service > /dev/null  2>&1
		systemctl start sssd.service > /dev/null  2>&1
		systemctl start docker.service > /dev/null  2>&1
	else
		echo "Failed to configure Docker for AD users"
	fi
}
##################################################
## Main entry point ##############################
##################################################
CURTIME=$(date | sed 's/ //g')
if [ -z $REGION ]; then
    get_region
fi
MAX_RETRIES=8
for i in $(seq 1 $MAX_RETRIES)
do
    echo "[$i] Attempt installing components"
    LINUX_DISTRO="AMAZON_LINUX"
    install_components
    if [ $? -eq 0 ]; then
        break
    fi
    sleep 30
done
echo "Components Installed Successfully."
echo "Getting Service Parameters"
get_serviceparams
REALM=$(echo "$DIRECTORY_NAME" | tr [a-z] [A-Z])
echo "Setting Hostname and Updating hosts file"
set_hostname
configure_hosts_file
if [ -z $DNS_IP_ADDRESS1 ] && [ -z $DNS_IP_ADDRESS2 ]; then
    DNS_ADDRESSES=$($AWSCLI ds describe-directories --region $REGION --directory-id $DIRECTORY_ID --output text | grep DNSIPADDR | awk '{print $2}')
    if [ $? -ne 0 ]; then
        echo "***Failed: DNS IPs not found" && exit 1
    fi
    DNS_IP_ADDRESS1=$(echo $DNS_ADDRESSES | awk '{ print $1 }')
    DNS_IP_ADDRESS2=$(echo $DNS_ADDRESSES | awk '{ print $2 }')
fi
## Configure DNS even if DHCP option set is used.
echo "Update DNS Config"
do_dns_config
echo "Allow password login via SSH"
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
systemctl restart sshd
if [ $? -ne 0 ]; then
   systemctl restart ssh
   if [ $? -ne 0 ]; then
      service sshd restart
   fi
   if [ $? -ne 0 ]; then
      service ssh restart
   fi
fi
print_vars
echo "Checking if directory is reachable"
is_directory_reachable
if [ $? -eq 0 ]; then
    config_nsswitch
    do_domainjoin
    config_sssd
    if [ -z $EFSSERVER ]
    then
	    echo "No EFS Server provided. Not configuring Autofs"
    else
	    config_autofs
    fi
    if [ -z $ADDOCKERGROUP ]
    then
	    echo "No Docker group provided. Not configuring Docker"
    else
	    config_docker
    fi
else
    echo "**Failed: Unable to reach DNS server"
    exit 1
fi
echo "Success"
exit 0
