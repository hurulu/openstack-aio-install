# This has been moved into puppet
#
#!/bin/bash

PASS=password
COMPUTE_PRIVATE_NET=192.168.0.0/24

function get_eth0_addr()
{
	eth0_ip=`ifconfig eth0|grep "inet addr"|awk '{print $2}'|cut -d: -f2`
	echo $eth0_ip
}

myip=$(get_eth0_addr)


function add_hostname()
{
	echo "$myip `hostname`" >>/etc/hosts
}
function add_grizzly_source()
{
        # Added to puppet...
	apt-get install -y ubuntu-cloud-keyring
	echo "deb http://ubuntu-cloud.archive.canonical.com/ubuntu precise-updates/grizzly main" >/etc/apt/sources.list.d/grizzly.list
	apt-get update -y
	apt-get upgrade -y
}

function set_rp_filter()
{
        # Added to puppet
	sed -i 's/^#net.ipv4.conf.all.rp_filter=1/net.ipv4.conf.all.rp_filter=0/' /etc/sysctl.conf
	sed -i 's/^#net.ipv4.conf.default.rp_filter=1/net.ipv4.conf.default.rp_filter=0/' /etc/sysctl.conf
	sysctl -w net.ipv4.conf.all.rp_filter=0
	sysctl -w net.ipv4.conf.default.rp_filter=0
}

function install_ntp()
{
        # Added to puppet
	apt-get install -y ntp
	service ntp restart
}

function install_mysql()
{
        # Added to puppet
	if [ $# -ne 1 ];then
		echo "Error : Default password for mysql root needed"
		return 1
	fi
	default_pass=$1
	apt-get install -yd mysql-server
	echo "debconf mysql-server/root_password password $default_pass" >/tmp/mysql_pass
	echo "debconf mysql-server/root_password_again password $default_pass" >>/tmp/mysql_pass
	debconf-set-selections /tmp/mysql_pass
	apt-get clean
	apt-get install -y mysql-server python-mysqldb
	sed -i 's/127.0.0.1/0.0.0.0/g' /etc/mysql/my.cnf
	service mysql restart
}

function install_rabbitmq()
{
        # Added to puppet
	pass=$1
	apt-get install -y rabbitmq-server
	rabbitmqctl change_password guest $pass
}

function install_keystone()
{
	
        # Added to puppet
	if [ $# -ne 2 ];then
		echo "Error : Hostname and password needed"
		return 1
	fi
	host=$1
	pass=$2
	conf=/etc/keystone/keystone.conf
	echo "CREATE DATABASE keystone;GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$pass';GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '$pass';FLUSH PRIVILEGES;"|mysql -uroot -p$pass
	apt-get install -y keystone python-keystone python-keystoneclient
	sed -i 's/^# admin_token = .*/admin_token = '$pass'/' $conf
	sed -i 's/^# bind_host = 0.0.0.0/# bind_host = 0.0.0.0/' $conf
	sed -i 's/^# public_port = 5000/public_port = 5000/' $conf
	sed -i 's/^# admin_port = 35357/admin_port = 35357/' $conf
	sed -i 's/^# verbose = False/verbose = True/' $conf
	sed -i 's/^# debug = False/debug = True/' $conf
	sed -i 's/^connection = sqlite.*/connection = mysql:\/\/keystone:'$pass'@'$host':3306\/keystone/' $conf
	sed -i 's/^# idle_timeout =.*/idle_timeout = 200/' $conf
	keystone-manage pki_setup
	service keystone restart
	keystone-manage db_sync
	echo "export OS_TENANT_NAME=admin" >>~/.novarc
	echo "export OS_USERNAME=admin" >>~/.novarc
	echo "export OS_PASSWORD=$pass" >>~/.novarc
	echo "export OS_AUTH_URL='http://$host:5000/v2.0/'" >>~/.novarc
	echo "export SERVICE_ENDPOINT='http://$host:35357/v2.0'" >>~/.novarc
	echo "export SERVICE_TOKEN=$pass" >>~/.novarc
	echo "source ~/.novarc" >>~/.bashrc
}

function keystone_data_gen()
{
        # Added to puppet
	ip=$1
	pass=$2
	#./keystone-data.sh
	#./keystone-endpoints.sh -K $ip
	./keystone_data.sh $ip $pass
}

function install_glance()
{
        if [ $# -ne 2 ];then
               echo "Error : Hostname and password needed"
               return 1
        fi
        host=$1
        pass=$2
	echo "CREATE DATABASE glance;GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '$pass';GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '$pass';FLUSH PRIVILEGES;"|mysql -uroot -p$pass
	apt-get install -y glance glance-api glance-registry python-glanceclient glance-common
	for i in /etc/glance/glance-api.conf /etc/glance/glance-registry.conf
	do
		sed -i 's/^sql_connection =.*/sql_connection = mysql:\/\/glance:'$pass'@'$host'\/glance/' $i
		sed -i 's/^admin_tenant_name =.*/admin_tenant_name = service/' $i
		sed -i 's/^admin_user =.*/admin_user = glance/' $i
		sed -i 's/^admin_password =.*/admin_password = '$pass'/' $i
		sed -i 's/.*notifier_strategy =.*/notifier_strategy = rabbit/' $i
		sed -i 's/^rabbit_password =.*/rabbit_password = '$pass'/' $i
		sed -i 's/^#flavor=.*/flavor = keystone/' $i
	done
	service glance-api restart && service glance-registry restart
	glance-manage db_sync
	#glance image-create --location http://uec-images.ubuntu.com/releases/12.04/release/ubuntu-12.04-server-cloudimg-amd64-disk1.img --is-public true --disk-format qcow2 --container-format bare --name "Ubuntu"
	glance image-create --location https://launchpad.net/cirros/trunk/0.3.0/+download/cirros-0.3.0-x86_64-disk.img --is-public true --disk-format qcow2 --container-format bare --name "Cirros"
	glance image-list
		
}

function controller_control()
{
	action=$1
	for i in rabbitmq-server nova-api nova-scheduler nova-novncproxy nova-cert nova-consoleauth 
	do
		service $i $action
	done
}

function edit_nova_conf()
{
        if [ $# -ne 3 ];then
              echo "Error : controller ip, passpassword and compute ip needed"
              return 1
        fi
        controller_ip=$1
        pass=$2
        compute_ip=$3
	conf=/etc/nova/nova.conf
	sed -i 's/1.1.1.1/'${controller_ip}'/g' $conf
	sed -i 's/2.2.2.2/'${compute_ip}'/g' $conf
	sed -i 's/^fixed_range=.*/fixed_range='${COMPUTE_PRIVATE_NET/\//\\\/}'/' $conf
	sed -i 's/^sql_connection=.*/sql_connection=mysql:\/\/nova:'$pass'@'${controller_ip}'\/nova/' $conf
	sed -i 's/^rabbit_password=.*/rabbit_password='$pass'/' $conf
	sed -i 's/^admin_password=.*/admin_password='$pass'/' $conf	
	sed -i 's/^fixed_range=.*/fixed_range='${COMPUTE_PRIVATE_NET}'/' $conf	
	sed -i 's/^auth_host =.*/auth_host = '${controller_ip}'/' /etc/nova/api-paste.ini
	sed -i 's/^admin_tenant_name =.*/admin_tenant_name = service/' /etc/nova/api-paste.ini
	sed -i 's/^admin_user =.*/admin_user = nova/' /etc/nova/api-paste.ini
	sed -i 's/^admin_password =.*/admin_password = '$pass'/' /etc/nova/api-paste.ini

}

function install_controller()
{
        if [ $# -ne 2 ];then
               echo "Error : Hostname and password needed"
               return 1
        fi
        host=$1
	subnet=`echo $host|awk -F. '{print $1"."$2"."$3".%"}'`
        pass=$2
	conf=/etc/nova/nova.conf
	echo "CREATE DATABASE nova;GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '$pass';GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '$pass';FLUSH PRIVILEGES;"|mysql -uroot -p$pass
	apt-get install -y  nova-novncproxy novnc nova-api nova-ajax-console-proxy nova-cert nova-consoleauth nova-doc nova-scheduler
	cp ./conf/nova.conf /etc/nova/
	edit_nova_conf $host $pass $host
	controller_control stop
	nova-manage db sync
	controller_control start
	nova-manage network create private --fixed_range_v4=${COMPUTE_PRIVATE_NET} --bridge_interface=br100 --num_networks=1 --network_size=256
}

function install_horizon()
{
	apt-get install -y memcached libapache2-mod-wsgi openstack-dashboard
}

function compute_control()
{
	#including nova-network(multi-host mode), nova-api
	for i in libvirt-bin nova-compute nova-network nova-api
	do
		service $i $1
	done
}
function install_compute()
{
        if [ $# -ne 3 ];then
              echo "Error : controller ip, passpassword and compute ip needed"
              return 1
        fi
        controller_ip=$1
        pass=$2
	compute_ip=$3
	apt-get install -y kvm libvirt-bin pm-utils
	echo 'cgroup_device_acl = ["/dev/null", "/dev/full", "/dev/zero","/dev/random", "/dev/urandom","/dev/ptmx", "/dev/kvm", "/dev/kqemu", "/dev/rtc", "/dev/hpet", "/dev/net/tun"]' >> /etc/libvirt/qemu.conf
	virsh net-destroy default
	virsh net-undefine default
	sed -i 's/^#listen_tls =.*/listen_tls = 0/' /etc/libvirt/libvirtd.conf
	sed -i 's/^#listen_tcp =.*/listen_tcp = 1/' /etc/libvirt/libvirtd.conf
	sed -i 's/^#auth_tcp =.*/auth_tcp = "none"/' /etc/libvirt/libvirtd.conf
	sed -i 's/libvirtd_opts=.*/libvirtd_opts="-d -l"/' /etc/init/libvirt-bin.conf
	sed -i 's/^libvirtd_opts=.*/libvirtd_opts="-d -l"/' /etc/default/libvirt-bin
	service libvirt-bin restart
	apt-get install -y nova-compute-qemu nova-network nova-conductor
	cp ./conf/nova.conf /etc/nova/
	edit_nova_conf $controller_ip $pass $compute_ip
	compute_control restart
}




####### MAIN #################
add_hostname

add_grizzly_source

set_rp_filter

install_ntp

install_mysql $PASS

install_rabbitmq $PASS

install_keystone localhost $PASS

source ~/.novarc
keystone_data_gen $myip $PASS

install_glance localhost $PASS

install_controller $myip $PASS

install_horizon

install_compute $myip $PASS $myip
