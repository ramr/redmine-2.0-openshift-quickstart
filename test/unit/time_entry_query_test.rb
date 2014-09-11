# Redmine - project management software
# Copyright (C) 2006-2013  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

require File.expand_path('../../test_helper', __FILE__)

class TimeEntryQueryTest < ActiveSupport::TestCase
  fixtures :projects, :users, :enumerations

  def test_activity_filter_should_consider_system_and_project_activities
    TimeEntry.delete_all
    system = TimeEntryActivity.create!(:name => 'Foo')
    override = TimeEntryActivity.create!(:name => 'Foo', :parent_id => system.id, :project_id => 1)
    other = TimeEntryActivity.create!(:name => 'Bar')
    TimeEntry.generate!(:activity => system, :hours => 1.0)
    TimeEntry.generate!(:activity => override, :hours => 2.0)
    TimeEntry.generate!(:activity => other, :hours => 4.0)

    query = TimeEntryQuery.new(:name => '_')
    query.add_filter('activity_id', '=', [system.id.to_s])
    assert_equal 3.0, query.results_scope.sum(:hours)

    query = TimeEntryQuery.new(:name => '_')
    query.add_filter('activity_id', '!', [system.id.to_s])
    assert_equal 4.0, query.results_scope.sum(:hours)
  end
end
