#
# Cookbook Name:: crowbar
# Recipe:: default
#
# Copyright 2011, Opscode, Inc. and Dell, Inc
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
#

include_recipe "apache2"

web_app "rubygems" do
  server_name "rubygems.org"
  docroot "/tftpboot/#{node[:platform]}_dvd/extra"
  template "rubygems_app.conf.erb"
  web_port 80
end

bash "force-apache-reload" do
  code "service httpd graceful"
end

%w{rake json syslogger sass simple-navigation 
   i18n haml net-http-digest_auth rails rainbows}.each {|g|
  gem_package g do
    action :install
  end
}

package "curl"

group "openstack"

user "openstack" do
  comment "Openstack User"
  gid "openstack"
  home "/home/openstack"
  password "$1$Woys8jvS$FjbKkYYpG175iSJf.pclw/"
  shell "/bin/bash"
end

group "crowbar"

user "crowbar" do
  comment "Crowbar"
  gid "crowbar"
  home "/home/random"
  shell "/bin/false"
end

directory "/root/.chef" do
  owner "root"
  group "root"
  mode "0700"
  action :create
end

cookbook_file "/etc/profile.d/crowbar.sh" do
  owner "root"
  group "root"
  mode "0755"
  action :create
  source "crowbar.sh"
end

cookbook_file "/root/.chef/knife.rb" do
  owner "root"
  group "root"
  mode "0600"
  action :create
  source "knife.rb"
end

directory "/home/openstack/.chef" do
  owner "openstack"
  group "openstack"
  mode "0700"
  action :create
end

cookbook_file "/home/openstack/.chef/knife.rb" do
  owner "openstack"
  group "openstack"
  mode "0600"
  action :create
  source "knife.rb"
end

bash "Add crowbar chef client" do
  environment ({'EDITOR' => '/bin/true'})
  code "knife client create crowbar -a --file /opt/dell/openstack_manager/config/client.pem -u chef-validator -k /etc/chef/validation.pem"
  not_if "knife client list -u crowbar -k /opt/dell/openstack_manager/config/client.pem"
end

file "/opt/dell/openstack_manager/log/production.log" do
  owner "crowbar"
  group "crowbar"
  mode "0666"
  action :create
end

file "/opt/dell/openstack_manager/tmp/queue.lock" do
  owner "crowbar"
  group "crowbar"
  mode "0644"
  action :create
end
file "/opt/dell/openstack_manager/tmp/ip.lock" do
  owner "crowbar"
  group "crowbar"
  mode "0644"
  action :create
end

unless node["crowbar"].nil? or node["crowbar"]["users"].nil? or node["crowbar"]["realm"].nil?
  web_port = node["crowbar"]["web_port"]
  realm = node["crowbar"]["realm"]
  users = node["crowbar"]["users"]
  # Fix passwords into digests.
  users.each do |k,h|
    h["digest"] = Digest::MD5.hexdigest("#{k}:#{realm}:#{h["password"]}") if h["digest"].nil?
  end

  template "/opt/dell/openstack_manager/htdigest" do
    source "htdigest.erb"
    variables(:users => users, :realm => realm)
    owner "crowbar"
    owner "crowbar"
    mode "0644"
  end
else
  web_port = 3000
  realm = nil
end

bash "set permissions" do
  code "chown -R crowbar:crowbar /opt/dell/openstack_manager"
  not_if "ls -al /opt/dell/openstack_manager/README | grep -q crowbar"
end

cookbook_file "/opt/dell/openstack_manager/config.ru" do
  source "config.ru"
  owner "crowbar"
  group "crowbar"
  mode "0644"
end

template "/opt/dell/openstack_manager/rainbows.cfg" do
  source "rainbows.cfg.erb"
  owner "crowbar"
  group "crowbar"
  mode "0644"
  variables(:web_host => "0.0.0.0", 
            :web_port => node["crowbar"]["web_port"] || 3000,
            :user => "crowbar",
            :concurrency_model => "EventMachine",
            :group => "crowbar",
            :logfile => "/opt/dell/openstack_manager/log/production.log",
            :app_location => "/opt/dell/openstack_manager")
end

bash "start rainbows" do
  code "cd /opt/dell/openstack_manager; rainbows -D -E production -c rainbows.cfg"
  not_if "pidof rainbows"
end

cookbook_file "/etc/init.d/crowbar" do
  owner "root"
  group "root"
  mode "0755"
  action :create
  source "crowbar"
end

["3", "5", "2"].each do |i|
  link "/etc/rc#{i}.d/S99xcrowbar" do
    action :create
    to "/etc/init.d/crowbar"
    not_if "test -L /etc/rc#{i}.d/S99xcrowbar"
  end
end

