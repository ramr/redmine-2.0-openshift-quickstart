# encoding: utf-8
#
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

module WorkflowsHelper
  def field_required?(field)
    field.is_a?(CustomField) ? field.is_required? : %w(project_id tracker_id subject priority_id is_private).include?(field)
  end

  def field_permission_tag(permissions, status, field, role)
    name = field.is_a?(CustomField) ? field.id.to_s : field
    options = [["", ""], [l(:label_readonly), "readonly"]]
    options << [l(:label_required), "required"] unless field_required?(field)
    html_options = {}
    selected = permissions[status.id][name]

    hidden = field.is_a?(CustomField) && !field.visible? && !role.custom_fields.to_a.include?(field)
    if hidden
      options[0][0] = l(:label_hidden)
      selected = ''
      html_options[:disabled] = true
    end

    select_tag("permissions[#{name}][#{status.id}]", options_for_select(options, selected), html_options)
  end
end
