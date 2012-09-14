Redmine on OpenShift
=========================
 
Redmine is a flexible project management web application. Written using Ruby on Rails framework, it is cross-platform and cross-database.

Redmine is open source and released under the terms of the GNU General Public License v2 (GPL).

More information can be found on the official Redmine set (www.redmine.org)
Running on OpenShift
--------------------

Create an account at http://openshift.redhat.com/

Create a ruby application (ruby-1.8 or ruby-1.9)

	rhc app create -a redmine -t ruby-1.9  # or ruby-1.8

Add mysql support to your application
    
	rhc app cartridge add -a redmine -c mysql-5.1

Make a note of the username, password, and host name as you will need to use these to login to the mysql database

Add this upstream Redmine quickstart repo

	cd redmine
	git remote add upstream -m master git://github.com/openshift/redmine-2.0-openshift-quickstart.git
	git pull -s recursive -X theirs upstream master

In order to be able to upload files attached to issues, you should add a
"files" directory/folder

	mkdir files

and remove the line /files/* from .gitignore to push that directory/folder
to all the gears (where your OpenShift application is running).

Alternatively, you can ssh to all the serving gears for your application
and create a directory/folder called "files" under redmine/repo

	mkdir redmine/repo/files

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

