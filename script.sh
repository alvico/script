#!/bin/bash -xe
#
setenforce 0
systemctl mask NetworkManager
systemctl stop NetworkManager
cat > /etc/sysconfig/network-scripts/ifcfg-enp0s8 << MIDO_EOF
DEVICE=enp0s8
BOOTPROTO=dhcp
NM_CONTROLLED=no
MIDO_EOF
cat > /etc/sysconfig/network-scripts/ifcfg-enp0s9 << MIDO_EOF
DEVICE=enp0s9
BOOTPROTO=dhcp
NM_CONTROLLED=no
MIDO_EOF
systemctl enable network.service
systemctl start network.service

cat >> /etc/resolv.conf << EOF_MIDO
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF_MIDO

# Repos
#
rpm -ivh http://yum.puppetlabs.com/puppetlabs-release-el-7.noarch.rpm
yum makecache fast


# packstack
yum install -y ntpdate
ntpdate pool.ntp.org
yum install -y https://repos.fedorapeople.org/repos/openstack/openstack-juno/rdo-release-juno-1.noarch.rpm
yum install -y epel-release


# Midonet
cat >> /etc/yum.repos.d/midonet.repo << EOF_MIDO
[midonet]
name=MidoNet
baseurl=http://bcn4.bcn.midokura.com:8081/artifactory/midonet/el7/master/nightly/all/noarch/
enabled=1
gpgcheck=0
gpgkey=http://bcn4.bcn.midokura.com:8081/artifactory/api/gpg/key/public

[midonet-openstack-integration]
name=MidoNet OpenStack Integration
baseurl=http://bcn4.bcn.midokura.com:8081/artifactory/midonet/el7/master/nightly/juno/noarch/
enabled=1
gpgcheck=1
gpgkey=http://bcn4.bcn.midokura.com:8081/artifactory/api/gpg/key/public

[midonet-misc]
name=MidoNet 3rd Party Tools and Libraries
baseurl=http://bcn4.bcn.midokura.com:8081/artifactory/midonet/el7/thirdparty/stable/all/x86_64/
enabled=1
gpgcheck=1
gpgkey=http://bcn4.bcn.midokura.com:8081/artifactory/api/gpg/key/public
EOF_MIDO

# Cassandra
cat >> /etc/yum.repos.d/cassandra.repo << EOF_MIDO
[datastax]
name= DataStax Repo for Apache Cassandra
baseurl=http://rpm.datastax.com/community
enabled=1
gpgcheck=0
EOF_MIDO

# Updating and installing dependencies
#
yum update -y
#cp /etc/pki/tls/certs/ca-bundle.crt /root/
#curl http://curl.haxx.se/ca/cacert.pem -o /etc/pki/tls/certs/ca-bundle.crt
yum update -y ca-certificates

# Tools
yum install -y augeas crudini screen wget


#
# Packstack
#
#

#yum install -y python-devel
#yum install -y gcc libgcc glibc libffi-devel libxml2-devel libxslt-devel openssl-devel zlib-devel bzip2-devel ncurses-devel
#yum install -y python-crypto
yum install -y python-pip

yum install -y firewalld
#systemctl restart firewalld
sudo systemctl stop firewalld
sudo systemctl mask firewalld
yum install -y iptables-services
systemctl enable iptables


IP=192.168.124.185
yum install -y openstack-packstack
packstack --install-hosts=$IP \
 --nagios-install=n \
 --os-swift-install=n \
 --os-ceilometer-install=n \
 --os-cinder-install=n \
 --os-glance-install=y \
 --os-heat-install=n \
 --os-horizon-install=n \
 --os-nova-install=y \
 --provision-demo=n

rc=$?; if [[ $rc != 0 ]]; then exit $rc; fi


yum remove -y openstack-neutron-openvswitch
systemctl stop openvswitch
systemctl mask openvswitch
systemctl stop neutron-l3-agent
systemctl mask neutron-l3-agent


ADMIN_TOKEN=$(crudini --get /etc/keystone/keystone.conf DEFAULT admin_token)
ADMIN_PASSWORD=$(grep "OS_PASSWORD" /root/keystonerc_admin | sed -e 's/"//g' | cut -f2 -d'=')
NEUTRON_DBPASS=$(crudini --get /root/packstack-answers-* general CONFIG_NEUTRON_DB_PW)



# Zookeeper
#

yum install -y java-1.7.0-openjdk-headless zookeeper

# Zookeeper expects the JRE to be found in the /usr/java/default/bin/ directory
# so if it is in a different location, you must create a symbolic link pointing
# to that location. To do so run the 2 following commands:

mkdir -p /usr/java/default/bin/
ln -s /usr/lib/jvm/jre-1.7.0-openjdk/bin/java /usr/java/default/bin/java

# Next we need to create the zookeeper data directory and assign permissions:

mkdir /var/lib/zookeeper/data
chmod 777 /var/lib/zookeeper/data

# Now we can edit the Zookeeper configuration file. We need to add the servers
# (in a prod installation you would have more than one zookeeper server in a
# cluster. For this example we are only using one. ). Edit the Zookeeper config
# file at /etc/zookeeper/zoo.cfg and add the following to the bottom of the
# file:

echo "server.1=$IP:2888:3888" >> /etc/zookeeper/zoo.cfg

# We need to set the Zookeeper ID on this server:

echo 1 > /var/lib/zookeeper/data/myid

systemctl enable zookeeper.service
systemctl start zookeeper.service

#
# Cassandra
#

yum install -y dsc20

sed -i -e "s/cluster_name:.*/cluster_name: 'midonet'/" /etc/cassandra/conf/cassandra.yaml

sed -i -e "s/listen_address:.*/listen_address: $IP/" /etc/cassandra/conf/cassandra.yaml

sed -i -e "s/seeds:.*/seeds: \"$IP\"/" /etc/cassandra/conf/cassandra.yaml
sed -i -e "s/rpc_address:.*/rpc_address: $IP/" /etc/cassandra/conf/cassandra.yaml

rm -rf /var/lib/cassandra/data/system

systemctl enable cassandra.service
systemctl start cassandra.service


#
# Midolman
#

yum install -y midolman
systemctl enable midolman.service
systemctl start midolman.service

#
# Midonet client
#
yum install -y python-midonetclient

#
# Midonet-api
#

yum install -y midonet-api

# Small inline python program that sets the proper xml values to midonet-api's
# web.xml
cat << MIDO_EOF | python -
from xml.dom import minidom

DOCUMENT_PATH = '/usr/share/midonet-api/WEB-INF/web.xml'


def set_value(param_name, value):
    value_node = param_node.parentNode.getElementsByTagName('param-value')[0]
    value_node.childNodes[0].data = value


doc = minidom.parse(DOCUMENT_PATH)
params = doc.getElementsByTagName('param-name')

for param_node in params:
    if param_node.childNodes[0].data == 'rest_api-base_uri':
        set_value(param_node, 'http://$IP:8081/midonet-api')
    elif param_node.childNodes[0].data == 'keystone-service_host':
        set_value(param_node, '$IP')
    elif param_node.childNodes[0].data == 'keystone-admin_token':
        set_value(param_node, '$ADMIN_TOKEN')
    elif param_node.childNodes[0].data == 'zookeeper-zookeeper_hosts':
        set_value(param_node, '$IP:2181')

with open(DOCUMENT_PATH, 'w') as f:
    f.write(doc.toprettyxml())
MIDO_EOF

yum install -y tomcat

cat << MIDO_EOF | augtool -L
set /augeas/load/Shellvars/incl[last()+1] /etc/tomcat/tomcat.conf
load
set /files/etc/tomcat/tomcat.conf/CONNECTOR_PORT 8081
save
MIDO_EOF

cat << MIDO_EOF | sudo augtool -L
set /augeas/load/Xml/incl[last()+1] /etc/tomcat/server.xml
load
set /files/etc/tomcat/server.xml/Server/Service/Connector[1]/#attribute/port 8081
save
MIDO_EOF


cat << MIDO_EOF > /etc/tomcat/Catalina/localhost/midonet-api.xml
<Context
    path="/midonet-api"
    docBase="/usr/share/midonet-api"
    antiResourceLocking="false"
    privileged="true"
/>
MIDO_EOF

systemctl enable tomcat.service
systemctl start tomcat.service


#
# Midonet-cli
#
#

yum install -y python-midonetclient
cat > ~/.midonetrc << MIDO_EOF
[cli]
api_url = http://$IP:8081/midonet-api
username = admin
password = $ADMIN_PASSWORD
project_id = admin
MIDO_EOF

cp /root/.midonetrc /home/vagrant/

# Create a tunnel zone
TUNNEL_ZONE=$(midonet-cli -e tunnel-zone create name gre type gre)
HOST_UUID=$(midonet-cli -e list host | awk '{print $2;}')
midonet-cli -e tunnel-zone $TUNNEL_ZONE add member host $HOST_UUID address $IP


#
# Keystone Integration
#

source ~/keystonerc_admin
keystone service-create --name midonet --type midonet --description "Midonet API Service"

keystone user-create --name midonet --pass midonet --tenant admin
keystone user-role-add --user midonet --role admin --tenant admin


#
# Neutron integration
#
yum install -y openstack-neutron python-neutron-plugin-midonet

crudini --set /etc/neutron/neutron.conf DEFAULT core_plugin midonet.neutron.plugin.MidonetPluginV2

mkdir /etc/neutron/plugins/midonet
cat > /etc/neutron/plugins/midonet/midonet.ini << MIDO_EOF
[DATABASE]
sql_connection = mysql://neutron:$NEUTRON_DBPASS@$IP/neutron
sql_max_retries = 100
[MIDONET]
# MidoNet API URL
midonet_uri = http://$IP:8081/midonet-api
# MidoNet administrative user in Keystone
username = midonet
password = midonet
# MidoNet administrative user's tenant
project_id = admin
auth_url = http://$IP:5000/v2.0
MIDO_EOF

rm -f /etc/neutron/plugin.ini
ln -s /etc/neutron/plugins/midonet/midonet.ini /etc/neutron/plugin.ini

# Comment out the service_plugins definitions
crudini --set /etc/neutron/neutron.conf DEFAULT service_plugins neutron.services.firewall.fwaas_plugin.FirewallPlugin
sed -i -e 's/^router_scheduler_driver/#router_scheduler_driver/' /etc/neutron/neutron.conf

# dhcp agent config
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT interface_driver neutron.agent.linux.interface.MidonetInterfaceDriver
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT dhcp_driver midonet.neutron.agent.midonet_driver.DhcpNoOpDriver
crudini --set /etc/neutron/dhcp_agent.ini DEFAULT enable_isolated_metadata True
crudini --set /etc/neutron/dhcp_agent.ini MIDONET midonet_uri http://$IP:8081/midonet-api
crudini --set /etc/neutron/dhcp_agent.ini MIDONET username midonet
crudini --set /etc/neutron/dhcp_agent.ini MIDONET password midonet


systemctl restart neutron-server
systemctl restart neutron-dhcp-agent
systemctl restart neutron-metadata-agent

#external network
neutron net-create ext-net --shared --router:external=True
neutron subnet-create ext-net --name ext-subnet --allocation-pool start=200.200.200.2,end=200.200.200.254 --disable-dhcp --gateway 200.200.200.1 200.200.200.0/24


# Fake uplink
ip link add type veth
ip link set dev veth0 up
ip link set dev veth1 up

brctl addbr uplinkbridge
brctl addif uplinkbridge veth0
ip addr add 172.19.0.1/30 dev uplinkbridge
ip link set dev uplinkbridge up

sysctl -w net.ipv4.ip_forward=1

ip route add 200.200.200.0/24 via 172.19.0.2

router=$(midonet-cli -e router list | awk '{print $2}')
port=$(midonet-cli -e router $router add port address 172.19.0.2 net 172.19.0.0/30)
midonet-cli -e router $router add route src 0.0.0.0/0 dst 0.0.0.0/0 type normal port router $router port $port gw 172.19.0.1
host=$(midonet-cli -e host list | awk '{print $2}')
midonet-cli -e host $host add binding port router $router port $port interface veth1


