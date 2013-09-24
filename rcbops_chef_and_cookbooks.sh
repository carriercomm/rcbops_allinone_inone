# Copyright [2013] [Kevin Carter]
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script will install several bits
# =====================================
# Install CHEF server (Latest Stable)
# Upload all of the RCBOPS cookbooks from the 4.1.2 branch


# Make the system key used for bootstrapping self
yes '' | ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ''
pushd /root/.ssh/
cat id_rsa.pub >> authorized_keys
popd

# Upgrade packages and repo list.
apt-get update && apt-get -y upgrade
apt-get install -y git curl lvm2

# Download/Install Chef
wget -O /tmp/chef_server.deb 'https://www.opscode.com/chef/download-server?p=ubuntu&pv=12.04&m=x86_64'
dpkg -i /tmp/chef_server.deb

# Configure Chef Vars.
mkdir /etc/chef-server
cat > /etc/chef-server/chef-server.rb <<EOF
nginx["ssl_port"] = 4000
nginx["non_ssl_port"] = 4080
nginx["enable_non_ssl"] = true
bookshelf['url'] = "https://#{node['ipaddress']}:4000"
EOF

# Reconfigure Chef.
chef-server-ctl reconfigure

# Install Chef Client.
bash <(wget -O - http://opscode.com/chef/install.sh)

# Configure Knife.
mkdir /root/.chef
cat > /root/.chef/knife.rb <<EOF
log_level                :info
log_location             STDOUT
node_name                'admin'
client_key               '/etc/chef-server/admin.pem'
validation_client_name   'chef-validator'
validation_key           '/etc/chef-server/chef-validator.pem'
chef_server_url          'https://localhost:4000'
cache_options( :path => '/root/.chef/checksums' )
cookbook_path            [ '/opt/allinoneinone/chef-cookbooks/cookbooks' ]
EOF

# Get RcbOps Cookbooks.
mkdir -p /opt/allinoneinone
git clone -b grizzly git://github.com/rcbops/chef-cookbooks.git /opt/allinoneinone/chef-cookbooks
pushd /opt/allinoneinone/chef-cookbooks
git submodule init
git checkout v4.1.2
git submodule update
knife cookbook site download -f /tmp/cron.tar.gz cron 1.2.6 && tar xf /tmp/cron.tar.gz -C /opt/allinoneinone/chef-cookbooks/cookbooks
knife cookbook site download -f /tmp/chef-client.tar.gz chef-client 3.0.6 && tar xf /tmp/chef-client.tar.gz -C /opt/allinoneinone/chef-cookbooks/cookbooks

knife cookbook upload -o /opt/allinoneinone/chef-cookbooks/cookbooks -a
knife role from file /opt/allinoneinone/chef-cookbooks/roles/*.rb
popd

# Set rcbops Chef Environment.
curl --silent https://raw.github.com/rsoprivatecloud/openstack-chef-deploy/master/environments/grizzly.json > allinoneinone.json.original

# Set the Default Chef Environment
$(which python) << EOF
import json
import subprocess

_ohai = subprocess.Popen(['ohai', '-l', 'fatal'], stdout=subprocess.PIPE)
ohai = _ohai.communicate()[0]
data = json.loads(ohai)

def get_network(interface):
    device = data['network']['interfaces'].get(interface)
    if device is not None:
        if device.get('routes'):
            routes = device['routes']
            for net in routes:
                if 'scope' in net:
                    return net.get('destination', '127.0.0.0/8')
                    break
        else:
            return '127.0.0.0/8'
    else:
        return '127.0.0.0/8'

network = get_network(interface='SOME_INTERFACE')

with open('allinoneinone.json.original', 'rb') as rcbops:
    env = json.loads(rcbops.read())

env['name'] = 'allinoneinone'
env['description'] = 'OpenStack Test All-In-One Deployment in One Server'
override = env['override_attributes']
users = override['keystone']['users']
users['admin']['password'] = 'secrete'
override['glance']['image_upload'] = True
override['nova'].update({'libvirt': {'virt_type': "qemu"}})
override['developer_mode'] = True
override['osops_networks']['management'] = network
override['osops_networks']['public'] = network
override['osops_networks']['nova'] = network
override['mysql']['root_network_acl'] = "%"

override.pop('hardware', None)
override.pop('enable_monit', None)
override.pop('monitoring', None)

with open('allinoneinone.json', 'wb') as rcbops:
    rcbops.write(json.dumps(env, indent=2))

EOF
