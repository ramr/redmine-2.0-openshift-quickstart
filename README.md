Redmine on OpenShift
=========================

Redmine is a flexible project management web application. Written using Ruby on Rails framework, it is cross-platform and cross-database.

Redmine is open source and released under the terms of the GNU General Public License v2 (GPL).

More information can be found at www.redmine.org

Running on OpenShift
--------------------

Create an account at https://www.openshift.com

Create a ruby application

	rhc app create redmine ruby-1.9 mysql-5.1 

Make a note of the username, password, and host name as you will need to use these to login to the mysql database.

The current version of Redmine based on Rails 3.2 which is not supported
on the Ruby 2.0 cartridge ([Rails#10877](https://github.com/rails/rails/issues/10877)).
Until Rails 4 version of Redmine is not released, you can try some of the community [forks](https://github.com/marutosi/redmine/tree/rails4.0.20140608-0).

Add this upstream Redmine quickstart repo

	cd redmine
	git remote add upstream -m master git://github.com/openshift/openshift-redmine-quickstart.git
	git pull -s recursive -X theirs upstream master

Then push the repo upstream

	git push

That's it, you can now checkout your application at:

	http://redmine-$yournamespace.rhcloud.com


Use the following to login to your new Redmine application running on OpenShift:

	username: admin
	password: admin


Changing the default admin password
-----------------------------------
Once your installation is complete, it is highly recommended that you change
the password for the Redmine admin user - see the Change password link at:

	http://redmine-$yournamespace.rhcloud.com/my/account

Version
-----------------------------------
Redmine 2.4
