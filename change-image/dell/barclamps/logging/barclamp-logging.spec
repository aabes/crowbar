
%define _topdir         BUILD_DIR
%define name		barclamp-logging
%define release		RPM_CONTEXT_NUMBER
%define version 	MAJOR_VERSION.MINOR_VERSION
%define buildroot	%{_topdir}/%{name}-%{version}-root

BuildRoot:		%{buildroot}
Summary: 		centralized logging system based on syslog
License: 		Apache 2.0
Name: 			%{name}
BuildArch:		noarch
Version: 		%{version}
Release: 		%{release}
Source: 		%{name}-%{version}.tar.gz
Prefix: 		/
Group: 			Development/Tools

%description
A Crowbar Barclamp that manages logging deployments within a Crowbar environment.

%prep
%setup -q

%build

%install
make install DESTDIR=${RPM_BUILD_ROOT}

%post 
cd /usr/share/barclamp-logging/chef/cookbooks
knife cookbook upload -o . -a -u chef-webui -k /etc/chef/webui.pem

cd /usr/share/barclamp-logging/chef/data_bags/crowbar
for i in *.json; do
    knife data bag from file crowbar $i
done

cd /usr/share/barclamp-logging/chef/roles
for i in *.rb; do
    knife role from file $i
done

service httpd graceful


%files
%defattr(-,root,root)
/usr/bin
/usr/share
/opt

