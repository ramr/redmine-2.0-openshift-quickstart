# This file is used by Rack-based servers to start the application.

require './thread-dumper' if /^1\.9/ === RUBY_VERSION

require ::File.expand_path('../config/environment',  __FILE__)
run RedmineApp::Application
