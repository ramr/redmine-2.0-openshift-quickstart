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

class Issue < ActiveRecord::Base
  include Redmine::SafeAttributes
  include Redmine::Utils::DateCalculation
  include Redmine::I18n

  belongs_to :project
  belongs_to :tracker
  belongs_to :status, :class_name => 'IssueStatus', :foreign_key => 'status_id'
  belongs_to :author, :class_name => 'User', :foreign_key => 'author_id'
  belongs_to :assigned_to, :class_name => 'Principal', :foreign_key => 'assigned_to_id'
  belongs_to :fixed_version, :class_name => 'Version', :foreign_key => 'fixed_version_id'
  belongs_to :priority, :class_name => 'IssuePriority', :foreign_key => 'priority_id'
  belongs_to :category, :class_name => 'IssueCategory', :foreign_key => 'category_id'

  has_many :journals, :as => :journalized, :dependent => :destroy
  has_many :visible_journals,
    :class_name => 'Journal',
    :as => :journalized,
    :conditions => Proc.new { 
      ["(#{Journal.table_name}.private_notes = ? OR (#{Project.allowed_to_condition(User.current, :view_private_notes)}))", false]
    },
    :readonly => true

  has_many :time_entries, :dependent => :delete_all
  has_and_belongs_to_many :changesets, :order => "#{Changeset.table_name}.committed_on ASC, #{Changeset.table_name}.id ASC"

  has_many :relations_from, :class_name => 'IssueRelation', :foreign_key => 'issue_from_id', :dependent => :delete_all
  has_many :relations_to, :class_name => 'IssueRelation', :foreign_key => 'issue_to_id', :dependent => :delete_all

  acts_as_nested_set :scope => 'root_id', :dependent => :destroy
  acts_as_attachable :after_add => :attachment_added, :after_remove => :attachment_removed
  acts_as_customizable
  acts_as_watchable
  acts_as_searchable :columns => ['subject', "#{table_name}.description", "#{Journal.table_name}.notes"],
                     :include => [:project, :visible_journals],
                     # sort by id so that limited eager loading doesn't break with postgresql
                     :order_column => "#{table_name}.id"
  acts_as_event :title => Proc.new {|o| "#{o.tracker.name} ##{o.id} (#{o.status}): #{o.subject}"},
                :url => Proc.new {|o| {:controller => 'issues', :action => 'show', :id => o.id}},
                :type => Proc.new {|o| 'issue' + (o.closed? ? ' closed' : '') }

  acts_as_activity_provider :find_options => {:include => [:project, :author, :tracker]},
                            :author_key => :author_id

  DONE_RATIO_OPTIONS = %w(issue_field issue_status)

  attr_reader :current_journal
  delegate :notes, :notes=, :private_notes, :private_notes=, :to => :current_journal, :allow_nil => true

  validates_presence_of :subject, :priority, :project, :tracker, :author, :status

  validates_length_of :subject, :maximum => 255
  validates_inclusion_of :done_ratio, :in => 0..100
  validates :estimated_hours, :numericality => {:greater_than_or_equal_to => 0, :allow_nil => true, :message => :invalid}
  validates :start_date, :date => true
  validates :due_date, :date => true
  validate :validate_issue, :validate_required_fields

  scope :visible, lambda {|*args|
    includes(:project).where(Issue.visible_condition(args.shift || User.current, *args))
  }

  scope :open, lambda {|*args|
    is_closed = args.size > 0 ? !args.first : false
    includes(:status).where("#{IssueStatus.table_name}.is_closed = ?", is_closed)
  }

  scope :recently_updated, lambda { order("#{Issue.table_name}.updated_on DESC") }
  scope :on_active_project, lambda {
    includes(:status, :project, :tracker).where("#{Project.table_name}.status = ?", Project::STATUS_ACTIVE)
  }
  scope :fixed_version, lambda {|versions|
    ids = [versions].flatten.compact.map {|v| v.is_a?(Version) ? v.id : v}
    ids.any? ? where(:fixed_version_id => ids) : where('1=0')
  }

  before_create :default_assign
  before_save :close_duplicates, :update_done_ratio_from_issue_status,
              :force_updated_on_change, :update_closed_on, :set_assigned_to_was
  after_save {|issue| issue.send :after_project_change if !issue.id_changed? && issue.project_id_changed?} 
  after_save :reschedule_following_issues, :update_nested_set_attributes,
             :update_parent_attributes, :create_journal
  # Should be after_create but would be called before previous after_save callbacks
  after_save :after_create_from_copy
  after_destroy :update_parent_attributes
  after_create :send_notification
  # Keep it at the end of after_save callbacks
  after_save :clear_assigned_to_was

  # Returns a SQL conditions string used to find all issues visible by the specified user
  def self.visible_condition(user, options={})
    Project.allowed_to_condition(user, :view_issues, options) do |role, user|
      if user.logged?
        case role.issues_visibility
        when 'all'
          nil
        when 'default'
          user_ids = [user.id] + user.groups.map(&:id).compact
          "(#{table_name}.is_private = #{connection.quoted_false} OR #{table_name}.author_id = #{user.id} OR #{table_name}.assigned_to_id IN (#{user_ids.join(',')}))"
        when 'own'
          user_ids = [user.id] + user.groups.map(&:id).compact
          "(#{table_name}.author_id = #{user.id} OR #{table_name}.assigned_to_id IN (#{user_ids.join(',')}))"
        else
          '1=0'
        end
      else
        "(#{table_name}.is_private = #{connection.quoted_false})"
      end
    end
  end

  # Returns true if usr or current user is allowed to view the issue
  def visible?(usr=nil)
    (usr || User.current).allowed_to?(:view_issues, self.project) do |role, user|
      if user.logged?
        case role.issues_visibility
        when 'all'
          true
        when 'default'
          !self.is_private? || (self.author == user || user.is_or_belongs_to?(assigned_to))
        when 'own'
          self.author == user || user.is_or_belongs_to?(assigned_to)
        else
          false
        end
      else
        !self.is_private?
      end
    end
  end

  # Returns true if user or current user is allowed to edit or add a note to the issue
  def editable?(user=User.current)
    user.allowed_to?(:edit_issues, project) || user.allowed_to?(:add_issue_notes, project)
  end

  def initialize(attributes=nil, *args)
    super
    if new_record?
      # set default values for new records only
      self.status ||= IssueStatus.default
      self.priority ||= IssuePriority.default
      self.watcher_user_ids = []
    end
  end

  def create_or_update
    super
  ensure
    @status_was = nil
  end
  private :create_or_update

  # AR#Persistence#destroy would raise and RecordNotFound exception
  # if the issue was already deleted or updated (non matching lock_version).
  # This is a problem when bulk deleting issues or deleting a project
  # (because an issue may already be deleted if its parent was deleted
  # first).
  # The issue is reloaded by the nested_set before being deleted so
  # the lock_version condition should not be an issue but we handle it.
  def destroy
    super
  rescue ActiveRecord::RecordNotFound
    # Stale or already deleted
    begin
      reload
    rescue ActiveRecord::RecordNotFound
      # The issue was actually already deleted
      @destroyed = true
      return freeze
    end
    # The issue was stale, retry to destroy
    super
  end

  alias :base_reload :reload
  def reload(*args)
    @workflow_rule_by_attribute = nil
    @assignable_versions = nil
    @relations = nil
    base_reload(*args)
  end

  # Overrides Redmine::Acts::Customizable::InstanceMethods#available_custom_fields
  def available_custom_fields
    (project && tracker) ? (project.all_issue_custom_fields & tracker.custom_fields.all) : []
  end

  def visible_custom_field_values(user=nil)
    user_real = user || User.current
    custom_field_values.select do |value|
      value.custom_field.visible_by?(project, user_real)
    end
  end

  # Copies attributes from another issue, arg can be an id or an Issue
  def copy_from(arg, options={})
    issue = arg.is_a?(Issue) ? arg : Issue.visible.find(arg)
    self.attributes = issue.attributes.dup.except("id", "root_id", "parent_id", "lft", "rgt", "created_on", "updated_on")
    self.custom_field_values = issue.custom_field_values.inject({}) {|h,v| h[v.custom_field_id] = v.value; h}
    self.status = issue.status
    self.author = User.current
    unless options[:attachments] == false
      self.attachments = issue.attachments.map do |attachement| 
        attachement.copy(:container => self)
      end
    end
    @copied_from = issue
    @copy_options = options
    self
  end

  # Returns an unsaved copy of the issue
  def copy(attributes=nil, copy_options={})
    copy = self.class.new.copy_from(self, copy_options)
    copy.attributes = attributes if attributes
    copy
  end

  # Returns true if the issue is a copy
  def copy?
    @copied_from.present?
  end

  # Moves/copies an issue to a new project and tracker
  # Returns the moved/copied issue on success, false on failure
  def move_to_project(new_project, new_tracker=nil, options={})
    ActiveSupport::Deprecation.warn "Issue#move_to_project is deprecated, use #project= instead."

    if options[:copy]
      issue = self.copy
    else
      issue = self
    end

    issue.init_journal(User.current, options[:notes])

    # Preserve previous behaviour
    # #move_to_project doesn't change tracker automatically
    issue.send :project=, new_project, true
    if new_tracker
      issue.tracker = new_tracker
    end
    # Allow bulk setting of attributes on the issue
    if options[:attributes]
      issue.attributes = options[:attributes]
    end

    issue.save ? issue : false
  end

  def status_id=(sid)
    self.status = nil
    result = write_attribute(:status_id, sid)
    @workflow_rule_by_attribute = nil
    result
  end

  def priority_id=(pid)
    self.priority = nil
    write_attribute(:priority_id, pid)
  end

  def category_id=(cid)
    self.category = nil
    write_attribute(:category_id, cid)
  end

  def fixed_version_id=(vid)
    self.fixed_version = nil
    write_attribute(:fixed_version_id, vid)
  end

  def tracker_id=(tid)
    self.tracker = nil
    result = write_attribute(:tracker_id, tid)
    @custom_field_values = nil
    @workflow_rule_by_attribute = nil
    result
  end

  def project_id=(project_id)
    if project_id.to_s != self.project_id.to_s
      self.project = (project_id.present? ? Project.find_by_id(project_id) : nil)
    end
  end

  def project=(project, keep_tracker=false)
    project_was = self.project
    write_attribute(:project_id, project ? project.id : nil)
    association_instance_set('project', project)
    if project_was && project && project_was != project
      @assignable_versions = nil

      unless keep_tracker || project.trackers.include?(tracker)
        self.tracker = project.trackers.first
      end
      # Reassign to the category with same name if any
      if category
        self.category = project.issue_categories.find_by_name(category.name)
      end
      # Keep the fixed_version if it's still valid in the new_project
      if fixed_version && fixed_version.project != project && !project.shared_versions.include?(fixed_version)
        self.fixed_version = nil
      end
      # Clear the parent task if it's no longer valid
      unless valid_parent_project?
        self.parent_issue_id = nil
      end
      @custom_field_values = nil
    end
  end

  def description=(arg)
    if arg.is_a?(String)
      arg = arg.gsub(/(\r\n|\n|\r)/, "\r\n")
    end
    write_attribute(:description, arg)
  end

  # Overrides assign_attributes so that project and tracker get assigned first
  def assign_attributes_with_project_and_tracker_first(new_attributes, *args)
    return if new_attributes.nil?
    attrs = new_attributes.dup
    attrs.stringify_keys!

    %w(project project_id tracker tracker_id).each do |attr|
      if attrs.has_key?(attr)
        send "#{attr}=", attrs.delete(attr)
      end
    end
    send :assign_attributes_without_project_and_tracker_first, attrs, *args
  end
  # Do not redefine alias chain on reload (see #4838)
  alias_method_chain(:assign_attributes, :project_and_tracker_first) unless method_defined?(:assign_attributes_without_project_and_tracker_first)

  def estimated_hours=(h)
    write_attribute :estimated_hours, (h.is_a?(String) ? h.to_hours : h)
  end

  safe_attributes 'project_id',
    :if => lambda {|issue, user|
      if issue.new_record?
        issue.copy?
      elsif user.allowed_to?(:move_issues, issue.project)
        Issue.allowed_target_projects_on_move.count > 1
      end
    }

  safe_attributes 'tracker_id',
    'status_id',
    'category_id',
    'assigned_to_id',
    'priority_id',
    'fixed_version_id',
    'subject',
    'description',
    'start_date',
    'due_date',
    'done_ratio',
    'estimated_hours',
    'custom_field_values',
    'custom_fields',
    'lock_version',
    'notes',
    :if => lambda {|issue, user| issue.new_record? || user.allowed_to?(:edit_issues, issue.project) }

  safe_attributes 'status_id',
    'assigned_to_id',
    'fixed_version_id',
    'done_ratio',
    'lock_version',
    'notes',
    :if => lambda {|issue, user| issue.new_statuses_allowed_to(user).any? }

  safe_attributes 'notes',
    :if => lambda {|issue, user| user.allowed_to?(:add_issue_notes, issue.project)}

  safe_attributes 'private_notes',
    :if => lambda {|issue, user| !issue.new_record? && user.allowed_to?(:set_notes_private, issue.project)} 

  safe_attributes 'watcher_user_ids',
    :if => lambda {|issue, user| issue.new_record? && user.allowed_to?(:add_issue_watchers, issue.project)} 

  safe_attributes 'is_private',
    :if => lambda {|issue, user|
      user.allowed_to?(:set_issues_private, issue.project) ||
        (issue.author == user && user.allowed_to?(:set_own_issues_private, issue.project))
    }

  safe_attributes 'parent_issue_id',
    :if => lambda {|issue, user| (issue.new_record? || user.allowed_to?(:edit_issues, issue.project)) &&
      user.allowed_to?(:manage_subtasks, issue.project)}

  def safe_attribute_names(user=nil)
    names = super
    names -= disabled_core_fields
    names -= read_only_attribute_names(user)
    names
  end

  # Safely sets attributes
  # Should be called from controllers instead of #attributes=
  # attr_accessible is too rough because we still want things like
  # Issue.new(:project => foo) to work
  def safe_attributes=(attrs, user=User.current)
    return unless attrs.is_a?(Hash)

    attrs = attrs.dup

    # Project and Tracker must be set before since new_statuses_allowed_to depends on it.
    if (p = attrs.delete('project_id')) && safe_attribute?('project_id')
      if allowed_target_projects(user).where(:id => p.to_i).exists?
        self.project_id = p
      end
    end

    if (t = attrs.delete('tracker_id')) && safe_attribute?('tracker_id')
      self.tracker_id = t
    end

    if (s = attrs.delete('status_id')) && safe_attribute?('status_id')
      if new_statuses_allowed_to(user).collect(&:id).include?(s.to_i)
        self.status_id = s
      end
    end

    attrs = delete_unsafe_attributes(attrs, user)
    return if attrs.empty?

    unless leaf?
      attrs.reject! {|k,v| %w(priority_id done_ratio start_date due_date estimated_hours).include?(k)}
    end

    if attrs['parent_issue_id'].present?
      s = attrs['parent_issue_id'].to_s
      unless (m = s.match(%r{\A#?(\d+)\z})) && (m[1] == parent_id.to_s || Issue.visible(user).exists?(m[1]))
        @invalid_parent_issue_id = attrs.delete('parent_issue_id')
      end
    end

    if attrs['custom_field_values'].present?
      editable_custom_field_ids = editable_custom_field_values(user).map {|v| v.custom_field_id.to_s}
      # TODO: use #select when ruby1.8 support is dropped
      attrs['custom_field_values'] = attrs['custom_field_values'].reject {|k, v| !editable_custom_field_ids.include?(k.to_s)}
    end

    if attrs['custom_fields'].present?
      editable_custom_field_ids = editable_custom_field_values(user).map {|v| v.custom_field_id.to_s}
      # TODO: use #select when ruby1.8 support is dropped
      attrs['custom_fields'] = attrs['custom_fields'].reject {|c| !editable_custom_field_ids.include?(c['id'].to_s)}
    end

    # mass-assignment security bypass
    assign_attributes attrs, :without_protection => true
  end

  def disabled_core_fields
    tracker ? tracker.disabled_core_fields : []
  end

  # Returns the custom_field_values that can be edited by the given user
  def editable_custom_field_values(user=nil)
    visible_custom_field_values(user).reject do |value|
      read_only_attribute_names(user).include?(value.custom_field_id.to_s)
    end
  end

  # Returns the names of attributes that are read-only for user or the current user
  # For users with multiple roles, the read-only fields are the intersection of
  # read-only fields of each role
  # The result is an array of strings where sustom fields are represented with their ids
  #
  # Examples:
  #   issue.read_only_attribute_names # => ['due_date', '2']
  #   issue.read_only_attribute_names(user) # => []
  def read_only_attribute_names(user=nil)
    workflow_rule_by_attribute(user).reject {|attr, rule| rule != 'readonly'}.keys
  end

  # Returns the names of required attributes for user or the current user
  # For users with multiple roles, the required fields are the intersection of
  # required fields of each role
  # The result is an array of strings where sustom fields are represented with their ids
  #
  # Examples:
  #   issue.required_attribute_names # => ['due_date', '2']
  #   issue.required_attribute_names(user) # => []
  def required_attribute_names(user=nil)
    workflow_rule_by_attribute(user).reject {|attr, rule| rule != 'required'}.keys
  end

  # Returns true if the attribute is required for user
  def required_attribute?(name, user=nil)
    required_attribute_names(user).include?(name.to_s)
  end

  # Returns a hash of the workflow rule by attribute for the given user
  #
  # Examples:
  #   issue.workflow_rule_by_attribute # => {'due_date' => 'required', 'start_date' => 'readonly'}
  def workflow_rule_by_attribute(user=nil)
    return @workflow_rule_by_attribute if @workflow_rule_by_attribute && user.nil?

    user_real = user || User.current
    roles = user_real.admin ? Role.all : user_real.roles_for_project(project)
    return {} if roles.empty?

    result = {}
    workflow_permissions = WorkflowPermission.where(:tracker_id => tracker_id, :old_status_id => status_id, :role_id => roles.map(&:id)).all
    if workflow_permissions.any?
      workflow_rules = workflow_permissions.inject({}) do |h, wp|
        h[wp.field_name] ||= []
        h[wp.field_name] << wp.rule
        h
      end
      workflow_rules.each do |attr, rules|
        next if rules.size < roles.size
        uniq_rules = rules.uniq
        if uniq_rules.size == 1
          result[attr] = uniq_rules.first
        else
          result[attr] = 'required'
        end
      end
    end
    @workflow_rule_by_attribute = result if user.nil?
    result
  end
  private :workflow_rule_by_attribute

  def done_ratio
    if Issue.use_status_for_done_ratio? && status && status.default_done_ratio
      status.default_done_ratio
    else
      read_attribute(:done_ratio)
    end
  end

  def self.use_status_for_done_ratio?
    Setting.issue_done_ratio == 'issue_status'
  end

  def self.use_field_for_done_ratio?
    Setting.issue_done_ratio == 'issue_field'
  end

  def validate_issue
    if due_date && start_date && (start_date_changed? || due_date_changed?) && due_date < start_date
      errors.add :due_date, :greater_than_start_date
    end

    if start_date && start_date_changed? && soonest_start && start_date < soonest_start
      errors.add :start_date, :earlier_than_minimum_start_date, :date => format_date(soonest_start)
    end

    if fixed_version
      if !assignable_versions.include?(fixed_version)
        errors.add :fixed_version_id, :inclusion
      elsif reopened? && fixed_version.closed?
        errors.add :base, I18n.t(:error_can_not_reopen_issue_on_closed_version)
      end
    end

    # Checks that the issue can not be added/moved to a disabled tracker
    if project && (tracker_id_changed? || project_id_changed?)
      unless project.trackers.include?(tracker)
        errors.add :tracker_id, :inclusion
      end
    end

    # Checks parent issue assignment
    if @invalid_parent_issue_id.present?
      errors.add :parent_issue_id, :invalid
    elsif @parent_issue
      if !valid_parent_project?(@parent_issue)
        errors.add :parent_issue_id, :invalid
      elsif (@parent_issue != parent) && (all_dependent_issues.include?(@parent_issue) || @parent_issue.all_dependent_issues.include?(self))
        errors.add :parent_issue_id, :invalid
      elsif !new_record?
        # moving an existing issue
        if @parent_issue.root_id != root_id
          # we can always move to another tree
        elsif move_possible?(@parent_issue)
          # move accepted inside tree
        else
          errors.add :parent_issue_id, :invalid
        end
      end
    end
  end

  # Validates the issue against additional workflow requirements
  def validate_required_fields
    user = new_record? ? author : current_journal.try(:user)

    required_attribute_names(user).each do |attribute|
      if attribute =~ /^\d+$/
        attribute = attribute.to_i
        v = custom_field_values.detect {|v| v.custom_field_id == attribute }
        if v && v.value.blank?
          errors.add :base, v.custom_field.name + ' ' + l('activerecord.errors.messages.blank')
        end
      else
        if respond_to?(attribute) && send(attribute).blank?
          errors.add attribute, :blank
        end
      end
    end
  end

  # Set the done_ratio using the status if that setting is set.  This will keep the done_ratios
  # even if the user turns off the setting later
  def update_done_ratio_from_issue_status
    if Issue.use_status_for_done_ratio? && status && status.default_done_ratio
      self.done_ratio = status.default_done_ratio
    end
  end

  def init_journal(user, notes = "")
    @current_journal ||= Journal.new(:journalized => self, :user => user, :notes => notes)
    if new_record?
      @current_journal.notify = false
    else
      @attributes_before_change = attributes.dup
      @custom_values_before_change = {}
      self.custom_field_values.each {|c| @custom_values_before_change.store c.custom_field_id, c.value }
    end
    @current_journal
  end

  # Returns the id of the last journal or nil
  def last_journal_id
    if new_record?
      nil
    else
      journals.maximum(:id)
    end
  end

  # Returns a scope for journals that have an id greater than journal_id
  def journals_after(journal_id)
    scope = journals.reorder("#{Journal.table_name}.id ASC")
    if journal_id.present?
      scope = scope.where("#{Journal.table_name}.id > ?", journal_id.to_i)
    end
    scope
  end

  # Returns the initial status of the issue
  # Returns nil for a new issue
  def status_was
    if status_id_was && status_id_was.to_i > 0
      @status_was ||= IssueStatus.find_by_id(status_id_was)
    end
  end

  # Return true if the issue is closed, otherwise false
  def closed?
    self.status.is_closed?
  end

  # Return true if the issue is being reopened
  def reopened?
    if !new_record? && status_id_changed?
      status_was = IssueStatus.find_by_id(status_id_was)
      status_new = IssueStatus.find_by_id(status_id)
      if status_was && status_new && status_was.is_closed? && !status_new.is_closed?
        return true
      end
    end
    false
  end

  # Return true if the issue is being closed
  def closing?
    if !new_record? && status_id_changed?
      if status_was && status && !status_was.is_closed? && status.is_closed?
        return true
      end
    end
    false
  end

  # Returns true if the issue is overdue
  def overdue?
    !due_date.nil? && (due_date < Date.today) && !status.is_closed?
  end

  # Is the amount of work done less than it should for the due date
  def behind_schedule?
    return false if start_date.nil? || due_date.nil?
    done_date = start_date + ((due_date - start_date + 1) * done_ratio / 100).floor
    return done_date <= Date.today
  end

  # Does this issue have children?
  def children?
    !leaf?
  end

  # Users the issue can be assigned to
  def assignable_users
    users = project.assignable_users
    users << author if author
    users << assigned_to if assigned_to
    users.uniq.sort
  end

  # Versions that the issue can be assigned to
  def assignable_versions
    return @assignable_versions if @assignable_versions

    versions = project.shared_versions.open.all
    if fixed_version
      if fixed_version_id_changed?
        # nothing to do
      elsif project_id_changed?
        if project.shared_versions.include?(fixed_version)
          versions << fixed_version
        end
      else
        versions << fixed_version
      end
    end
    @assignable_versions = versions.uniq.sort
  end

  # Returns true if this issue is blocked by another issue that is still open
  def blocked?
    !relations_to.detect {|ir| ir.relation_type == 'blocks' && !ir.issue_from.closed?}.nil?
  end

  # Returns an array of statuses that user is able to apply
  def new_statuses_allowed_to(user=User.current, include_default=false)
    if new_record? && @copied_from
      [IssueStatus.default, @copied_from.status].compact.uniq.sort
    else
      initial_status = nil
      if new_record?
        initial_status = IssueStatus.default
      elsif status_id_was
        initial_status = IssueStatus.find_by_id(status_id_was)
      end
      initial_status ||= status

      initial_assigned_to_id = assigned_to_id_changed? ? assigned_to_id_was : assigned_to_id
      assignee_transitions_allowed = initial_assigned_to_id.present? && 
        (user.id == initial_assigned_to_id || user.group_ids.include?(initial_assigned_to_id))

      statuses = initial_status.find_new_statuses_allowed_to(
        user.admin ? Role.all : user.roles_for_project(project),
        tracker,
        author == user,
        assignee_transitions_allowed
        )
      statuses << initial_status unless statuses.empty?
      statuses << IssueStatus.default if include_default
      statuses = statuses.compact.uniq.sort
      blocked? ? statuses.reject {|s| s.is_closed?} : statuses
    end
  end

  # Returns the previous assignee if changed
  def assigned_to_was
    # assigned_to_id_was is reset before after_save callbacks
    user_id = @previous_assigned_to_id || assigned_to_id_was
    if user_id && user_id != assigned_to_id
      @assigned_to_was ||= User.find_by_id(user_id)
    end
  end

  # Returns the users that should be notified
  def notified_users
    notified = []
    # Author and assignee are always notified unless they have been
    # locked or don't want to be notified
    notified << author if author
    if assigned_to
      notified += (assigned_to.is_a?(Group) ? assigned_to.users : [assigned_to])
    end
    if assigned_to_was
      notified += (assigned_to_was.is_a?(Group) ? assigned_to_was.users : [assigned_to_was])
    end
    notified = notified.select {|u| u.active? && u.notify_about?(self)}

    notified += project.notified_users
    notified.uniq!
    # Remove users that can not view the issue
    notified.reject! {|user| !visible?(user)}
    notified
  end

  # Returns the email addresses that should be notified
  def recipients
    notified_users.collect(&:mail)
  end

  def each_notification(users, &block)
    if users.any?
      if custom_field_values.detect {|value| !value.custom_field.visible?}
        users_by_custom_field_visibility = users.group_by do |user|
          visible_custom_field_values(user).map(&:custom_field_id).sort
        end
        users_by_custom_field_visibility.values.each do |users|
          yield(users)
        end
      else
        yield(users)
      end
    end
  end

  # Returns the number of hours spent on this issue
  def spent_hours
    @spent_hours ||= time_entries.sum(:hours) || 0
  end

  # Returns the total number of hours spent on this issue and its descendants
  #
  # Example:
  #   spent_hours => 0.0
  #   spent_hours => 50.2
  def total_spent_hours
    @total_spent_hours ||= self_and_descendants.sum("#{TimeEntry.table_name}.hours",
      :joins => "LEFT JOIN #{TimeEntry.table_name} ON #{TimeEntry.table_name}.issue_id = #{Issue.table_name}.id").to_f || 0.0
  end

  def relations
    @relations ||= IssueRelation::Relations.new(self, (relations_from + relations_to).sort)
  end

  # Preloads relations for a collection of issues
  def self.load_relations(issues)
    if issues.any?
      relations = IssueRelation.where("issue_from_id IN (:ids) OR issue_to_id IN (:ids)", :ids => issues.map(&:id)).all
      issues.each do |issue|
        issue.instance_variable_set "@relations", relations.select {|r| r.issue_from_id == issue.id || r.issue_to_id == issue.id}
      end
    end
  end

  # Preloads visible spent time for a collection of issues
  def self.load_visible_spent_hours(issues, user=User.current)
    if issues.any?
      hours_by_issue_id = TimeEntry.visible(user).group(:issue_id).sum(:hours)
      issues.each do |issue|
        issue.instance_variable_set "@spent_hours", (hours_by_issue_id[issue.id] || 0)
      end
    end
  end

  # Preloads visible relations for a collection of issues
  def self.load_visible_relations(issues, user=User.current)
    if issues.any?
      issue_ids = issues.map(&:id)
      # Relations with issue_from in given issues and visible issue_to
      relations_from = IssueRelation.includes(:issue_to => [:status, :project]).where(visible_condition(user)).where(:issue_from_id => issue_ids).all
      # Relations with issue_to in given issues and visible issue_from
      relations_to = IssueRelation.includes(:issue_from => [:status, :project]).where(visible_condition(user)).where(:issue_to_id => issue_ids).all

      issues.each do |issue|
        relations =
          relations_from.select {|relation| relation.issue_from_id == issue.id} +
          relations_to.select {|relation| relation.issue_to_id == issue.id}

        issue.instance_variable_set "@relations", IssueRelation::Relations.new(issue, relations.sort)
      end
    end
  end

  # Finds an issue relation given its id.
  def find_relation(relation_id)
    IssueRelation.where("issue_to_id = ? OR issue_from_id = ?", id, id).find(relation_id)
  end

  # Returns all the other issues that depend on the issue
  # The algorithm is a modified breadth first search (bfs)
  def all_dependent_issues(except=[])
    # The found dependencies
    dependencies = []

    # The visited flag for every node (issue) used by the breadth first search
    eNOT_DISCOVERED         = 0       # The issue is "new" to the algorithm, it has not seen it before.

    ePROCESS_ALL            = 1       # The issue is added to the queue. Process both children and relations of
                                      # the issue when it is processed.

    ePROCESS_RELATIONS_ONLY = 2       # The issue was added to the queue and will be output as dependent issue,
                                      # but its children will not be added to the queue when it is processed.

    eRELATIONS_PROCESSED    = 3       # The related issues, the parent issue and the issue itself have been added to
                                      # the queue, but its children have not been added.

    ePROCESS_CHILDREN_ONLY  = 4       # The relations and the parent of the issue have been added to the queue, but
                                      # the children still need to be processed.

    eALL_PROCESSED          = 5       # The issue and all its children, its parent and its related issues have been
                                      # added as dependent issues. It needs no further processing.

    issue_status = Hash.new(eNOT_DISCOVERED)

    # The queue
    queue = []

    # Initialize the bfs, add start node (self) to the queue
    queue << self
    issue_status[self] = ePROCESS_ALL

    while (!queue.empty?) do
      current_issue = queue.shift
      current_issue_status = issue_status[current_issue]
      dependencies << current_issue

      # Add parent to queue, if not already in it.
      parent = current_issue.parent
      parent_status = issue_status[parent]

      if parent && (parent_status == eNOT_DISCOVERED) && !except.include?(parent)
        queue << parent
        issue_status[parent] = ePROCESS_RELATIONS_ONLY
      end

      # Add children to queue, but only if they are not already in it and
      # the children of the current node need to be processed.
      if (current_issue_status == ePROCESS_CHILDREN_ONLY || current_issue_status == ePROCESS_ALL)
        current_issue.children.each do |child|
          next if except.include?(child)

          if (issue_status[child] == eNOT_DISCOVERED)
            queue << child
            issue_status[child] = ePROCESS_ALL
          elsif (issue_status[child] == eRELATIONS_PROCESSED)
            queue << child
            issue_status[child] = ePROCESS_CHILDREN_ONLY
          elsif (issue_status[child] == ePROCESS_RELATIONS_ONLY)
            queue << child
            issue_status[child] = ePROCESS_ALL
          end
        end
      end

      # Add related issues to the queue, if they are not already in it.
      current_issue.relations_from.map(&:issue_to).each do |related_issue|
        next if except.include?(related_issue)

        if (issue_status[related_issue] == eNOT_DISCOVERED)
          queue << related_issue
          issue_status[related_issue] = ePROCESS_ALL
        elsif (issue_status[related_issue] == eRELATIONS_PROCESSED)
          queue << related_issue
          issue_status[related_issue] = ePROCESS_CHILDREN_ONLY
        elsif (issue_status[related_issue] == ePROCESS_RELATIONS_ONLY)
          queue << related_issue
          issue_status[related_issue] = ePROCESS_ALL
        end
      end

      # Set new status for current issue
      if (current_issue_status == ePROCESS_ALL) || (current_issue_status == ePROCESS_CHILDREN_ONLY)
        issue_status[current_issue] = eALL_PROCESSED
      elsif (current_issue_status == ePROCESS_RELATIONS_ONLY)
        issue_status[current_issue] = eRELATIONS_PROCESSED
      end
    end # while

    # Remove the issues from the "except" parameter from the result array
    dependencies -= except
    dependencies.delete(self)

    dependencies
  end

  # Returns an array of issues that duplicate this one
  def duplicates
    relations_to.select {|r| r.relation_type == IssueRelation::TYPE_DUPLICATES}.collect {|r| r.issue_from}
  end

  # Returns the due date or the target due date if any
  # Used on gantt chart
  def due_before
    due_date || (fixed_version ? fixed_version.effective_date : nil)
  end

  # Returns the time scheduled for this issue.
  #
  # Example:
  #   Start Date: 2/26/09, End Date: 3/04/09
  #   duration => 6
  def duration
    (start_date && due_date) ? due_date - start_date : 0
  end

  # Returns the duration in working days
  def working_duration
    (start_date && due_date) ? working_days(start_date, due_date) : 0
  end

  def soonest_start(reload=false)
    @soonest_start = nil if reload
    @soonest_start ||= (
        relations_to(reload).collect{|relation| relation.successor_soonest_start} +
        [(@parent_issue || parent).try(:soonest_start)]
      ).compact.max
  end

  # Sets start_date on the given date or the next working day
  # and changes due_date to keep the same working duration.
  def reschedule_on(date)
    wd = working_duration
    date = next_working_date(date)
    self.start_date = date
    self.due_date = add_working_days(date, wd)
  end

  # Reschedules the issue on the given date or the next working day and saves the record.
  # If the issue is a parent task, this is done by rescheduling its subtasks.
  def reschedule_on!(date)
    return if date.nil?
    if leaf?
      if start_date.nil? || start_date != date
        if start_date && start_date > date
          # Issue can not be moved earlier than its soonest start date
          date = [soonest_start(true), date].compact.max
        end
        reschedule_on(date)
        begin
          save
        rescue ActiveRecord::StaleObjectError
          reload
          reschedule_on(date)
          save
        end
      end
    else
      leaves.each do |leaf|
        if leaf.start_date
          # Only move subtask if it starts at the same date as the parent
          # or if it starts before the given date
          if start_date == leaf.start_date || date > leaf.start_date 
            leaf.reschedule_on!(date)
          end
        else
          leaf.reschedule_on!(date)
        end
      end
    end
  end

  def <=>(issue)
    if issue.nil?
      -1
    elsif root_id != issue.root_id
      (root_id || 0) <=> (issue.root_id || 0)
    else
      (lft || 0) <=> (issue.lft || 0)
    end
  end

  def to_s
    "#{tracker} ##{id}: #{subject}"
  end

  # Returns a string of css classes that apply to the issue
  def css_classes(user=User.current)
    s = "issue tracker-#{tracker_id} status-#{status_id} #{priority.try(:css_classes)}"
    s << ' closed' if closed?
    s << ' overdue' if overdue?
    s << ' child' if child?
    s << ' parent' unless leaf?
    s << ' private' if is_private?
    if user.logged?
      s << ' created-by-me' if author_id == user.id
      s << ' assigned-to-me' if assigned_to_id == user.id
      s << ' assigned-to-my-group' if user.groups.any? {|g| g.id = assigned_to_id}
    end
    s
  end

  # Unassigns issues from +version+ if it's no longer shared with issue's project
  def self.update_versions_from_sharing_change(version)
    # Update issues assigned to the version
    update_versions(["#{Issue.table_name}.fixed_version_id = ?", version.id])
  end

  # Unassigns issues from versions that are no longer shared
  # after +project+ was moved
  def self.update_versions_from_hierarchy_change(project)
    moved_project_ids = project.self_and_descendants.reload.collect(&:id)
    # Update issues of the moved projects and issues assigned to a version of a moved project
    Issue.update_versions(["#{Version.table_name}.project_id IN (?) OR #{Issue.table_name}.project_id IN (?)", moved_project_ids, moved_project_ids])
  end

  def parent_issue_id=(arg)
    s = arg.to_s.strip.presence
    if s && (m = s.match(%r{\A#?(\d+)\z})) && (@parent_issue = Issue.find_by_id(m[1]))
      @parent_issue.id
      @invalid_parent_issue_id = nil
    elsif s.blank?
      @parent_issue = nil
      @invalid_parent_issue_id = nil
    else
      @parent_issue = nil
      @invalid_parent_issue_id = arg
    end
  end

  def parent_issue_id
    if @invalid_parent_issue_id
      @invalid_parent_issue_id
    elsif instance_variable_defined? :@parent_issue
      @parent_issue.nil? ? nil : @parent_issue.id
    else
      parent_id
    end
  end

  # Returns true if issue's project is a valid
  # parent issue project
  def valid_parent_project?(issue=parent)
    return true if issue.nil? || issue.project_id == project_id

    case Setting.cross_project_subtasks
    when 'system'
      true
    when 'tree'
      issue.project.root == project.root
    when 'hierarchy'
      issue.project.is_or_is_ancestor_of?(project) || issue.project.is_descendant_of?(project)
    when 'descendants'
      issue.project.is_or_is_ancestor_of?(project)
    else
      false
    end
  end

  # Extracted from the ReportsController.
  def self.by_tracker(project)
    count_and_group_by(:project => project,
                       :field => 'tracker_id',
                       :joins => Tracker.table_name)
  end

  def self.by_version(project)
    count_and_group_by(:project => project,
                       :field => 'fixed_version_id',
                       :joins => Version.table_name)
  end

  def self.by_priority(project)
    count_and_group_by(:project => project,
                       :field => 'priority_id',
                       :joins => IssuePriority.table_name)
  end

  def self.by_category(project)
    count_and_group_by(:project => project,
                       :field => 'category_id',
                       :joins => IssueCategory.table_name)
  end

  def self.by_assigned_to(project)
    count_and_group_by(:project => project,
                       :field => 'assigned_to_id',
                       :joins => User.table_name)
  end

  def self.by_author(project)
    count_and_group_by(:project => project,
                       :field => 'author_id',
                       :joins => User.table_name)
  end

  def self.by_subproject(project)
    ActiveRecord::Base.connection.select_all("select    s.id as status_id, 
                                                s.is_closed as closed, 
                                                #{Issue.table_name}.project_id as project_id,
                                                count(#{Issue.table_name}.id) as total 
                                              from 
                                                #{Issue.table_name}, #{Project.table_name}, #{IssueStatus.table_name} s
                                              where 
                                                #{Issue.table_name}.status_id=s.id
                                                and #{Issue.table_name}.project_id = #{Project.table_name}.id
                                                and #{visible_condition(User.current, :project => project, :with_subprojects => true)}
                                                and #{Issue.table_name}.project_id <> #{project.id}
                                              group by s.id, s.is_closed, #{Issue.table_name}.project_id") if project.descendants.active.any?
  end
  # End ReportsController extraction

  # Returns a scope of projects that user can assign the issue to
  def allowed_target_projects(user=User.current)
    if new_record?
      Project.where(Project.allowed_to_condition(user, :add_issues))
    else
      self.class.allowed_target_projects_on_move(user)
    end
  end

  # Returns a scope of projects that user can move issues to
  def self.allowed_target_projects_on_move(user=User.current)
    Project.where(Project.allowed_to_condition(user, :move_issues))
  end

  private

  def after_project_change
    # Update project_id on related time entries
    TimeEntry.update_all(["project_id = ?", project_id], {:issue_id => id})

    # Delete issue relations
    unless Setting.cross_project_issue_relations?
      relations_from.clear
      relations_to.clear
    end

    # Move subtasks that were in the same project
    children.each do |child|
      next unless child.project_id == project_id_was
      # Change project and keep project
      child.send :project=, project, true
      unless child.save
        raise ActiveRecord::Rollback
      end
    end
  end

  # Callback for after the creation of an issue by copy
  # * adds a "copied to" relation with the copied issue
  # * copies subtasks from the copied issue
  def after_create_from_copy
    return unless copy? && !@after_create_from_copy_handled

    if (@copied_from.project_id == project_id || Setting.cross_project_issue_relations?) && @copy_options[:link] != false
      relation = IssueRelation.new(:issue_from => @copied_from, :issue_to => self, :relation_type => IssueRelation::TYPE_COPIED_TO)
      unless relation.save
        logger.error "Could not create relation while copying ##{@copied_from.id} to ##{id} due to validation errors: #{relation.errors.full_messages.join(', ')}" if logger
      end
    end

    unless @copied_from.leaf? || @copy_options[:subtasks] == false
      copy_options = (@copy_options || {}).merge(:subtasks => false)
      copied_issue_ids = {@copied_from.id => self.id}
      @copied_from.reload.descendants.reorder("#{Issue.table_name}.lft").each do |child|
        # Do not copy self when copying an issue as a descendant of the copied issue
        next if child == self
        # Do not copy subtasks of issues that were not copied
        next unless copied_issue_ids[child.parent_id]
        # Do not copy subtasks that are not visible to avoid potential disclosure of private data
        unless child.visible?
          logger.error "Subtask ##{child.id} was not copied during ##{@copied_from.id} copy because it is not visible to the current user" if logger
          next
        end
        copy = Issue.new.copy_from(child, copy_options)
        copy.author = author
        copy.project = project
        copy.parent_issue_id = copied_issue_ids[child.parent_id]
        unless copy.save
          logger.error "Could not copy subtask ##{child.id} while copying ##{@copied_from.id} to ##{id} due to validation errors: #{copy.errors.full_messages.join(', ')}" if logger
          next
        end
        copied_issue_ids[child.id] = copy.id
      end
    end
    @after_create_from_copy_handled = true
  end

  def update_nested_set_attributes
    if root_id.nil?
      # issue was just created
      self.root_id = (@parent_issue.nil? ? id : @parent_issue.root_id)
      set_default_left_and_right
      Issue.update_all(["root_id = ?, lft = ?, rgt = ?", root_id, lft, rgt], ["id = ?", id])
      if @parent_issue
        move_to_child_of(@parent_issue)
      end
    elsif parent_issue_id != parent_id
      update_nested_set_attributes_on_parent_change
    end
    remove_instance_variable(:@parent_issue) if instance_variable_defined?(:@parent_issue)
  end

  # Updates the nested set for when an existing issue is moved
  def update_nested_set_attributes_on_parent_change
    former_parent_id = parent_id
    # moving an existing issue
    if @parent_issue && @parent_issue.root_id == root_id
      # inside the same tree
      move_to_child_of(@parent_issue)
    else
      # to another tree
      unless root?
        move_to_right_of(root)
      end
      old_root_id = root_id
      self.root_id = (@parent_issue.nil? ? id : @parent_issue.root_id )
      target_maxright = nested_set_scope.maximum(right_column_name) || 0
      offset = target_maxright + 1 - lft
      Issue.update_all(["root_id = ?, lft = lft + ?, rgt = rgt + ?", root_id, offset, offset],
                        ["root_id = ? AND lft >= ? AND rgt <= ? ", old_root_id, lft, rgt])
      self[left_column_name] = lft + offset
      self[right_column_name] = rgt + offset
      if @parent_issue
        move_to_child_of(@parent_issue)
      end
    end
    # delete invalid relations of all descendants
    self_and_descendants.each do |issue|
      issue.relations.each do |relation|
        relation.destroy unless relation.valid?
      end
    end
    # update former parent
    recalculate_attributes_for(former_parent_id) if former_parent_id
  end

  def update_parent_attributes
    recalculate_attributes_for(parent_id) if parent_id
  end

  def recalculate_attributes_for(issue_id)
    if issue_id && p = Issue.find_by_id(issue_id)
      # priority = highest priority of children
      if priority_position = p.children.maximum("#{IssuePriority.table_name}.position", :joins => :priority)
        p.priority = IssuePriority.find_by_position(priority_position)
      end

      # start/due dates = lowest/highest dates of children
      p.start_date = p.children.minimum(:start_date)
      p.due_date = p.children.maximum(:due_date)
      if p.start_date && p.due_date && p.due_date < p.start_date
        p.start_date, p.due_date = p.due_date, p.start_date
      end

      # done ratio = weighted average ratio of leaves
      unless Issue.use_status_for_done_ratio? && p.status && p.status.default_done_ratio
        leaves_count = p.leaves.count
        if leaves_count > 0
          average = p.leaves.average(:estimated_hours).to_f
          if average == 0
            average = 1
          end
          done = p.leaves.sum("COALESCE(CASE WHEN estimated_hours > 0 THEN estimated_hours ELSE NULL END, #{average}) " +
			"* (CASE WHEN is_closed = #{connection.quoted_true} THEN 100 ELSE COALESCE(done_ratio, 0) END)", :joins => :status).to_f
          progress = done / (average * leaves_count)
          p.done_ratio = progress.round
        end
      end

      # estimate = sum of leaves estimates
      p.estimated_hours = p.leaves.sum(:estimated_hours).to_f
      p.estimated_hours = nil if p.estimated_hours == 0.0

      # ancestors will be recursively updated
      p.save(:validate => false)
    end
  end

  # Update issues so their versions are not pointing to a
  # fixed_version that is not shared with the issue's project
  def self.update_versions(conditions=nil)
    # Only need to update issues with a fixed_version from
    # a different project and that is not systemwide shared
    Issue.includes(:project, :fixed_version).
      where("#{Issue.table_name}.fixed_version_id IS NOT NULL" +
        " AND #{Issue.table_name}.project_id <> #{Version.table_name}.project_id" +
        " AND #{Version.table_name}.sharing <> 'system'").
      where(conditions).each do |issue|
      next if issue.project.nil? || issue.fixed_version.nil?
      unless issue.project.shared_versions.include?(issue.fixed_version)
        issue.init_journal(User.current)
        issue.fixed_version = nil
        issue.save
      end
    end
  end

  # Callback on file attachment
  def attachment_added(obj)
    if @current_journal && !obj.new_record?
      @current_journal.details << JournalDetail.new(:property => 'attachment', :prop_key => obj.id, :value => obj.filename)
    end
  end

  # Callback on attachment deletion
  def attachment_removed(obj)
    if @current_journal && !obj.new_record?
      @current_journal.details << JournalDetail.new(:property => 'attachment', :prop_key => obj.id, :old_value => obj.filename)
      @current_journal.save
    end
  end

  # Default assignment based on category
  def default_assign
    if assigned_to.nil? && category && category.assigned_to
      self.assigned_to = category.assigned_to
    end
  end

  # Updates start/due dates of following issues
  def reschedule_following_issues
    if start_date_changed? || due_date_changed?
      relations_from.each do |relation|
        relation.set_issue_to_dates
      end
    end
  end

  # Closes duplicates if the issue is being closed
  def close_duplicates
    if closing?
      duplicates.each do |duplicate|
        # Reload is need in case the duplicate was updated by a previous duplicate
        duplicate.reload
        # Don't re-close it if it's already closed
        next if duplicate.closed?
        # Same user and notes
        if @current_journal
          duplicate.init_journal(@current_journal.user, @current_journal.notes)
        end
        duplicate.update_attribute :status, self.status
      end
    end
  end

  # Make sure updated_on is updated when adding a note and set updated_on now
  # so we can set closed_on with the same value on closing
  def force_updated_on_change
    if @current_journal || changed?
      self.updated_on = current_time_from_proper_timezone
      if new_record?
        self.created_on = updated_on
      end
    end
  end

  # Callback for setting closed_on when the issue is closed.
  # The closed_on attribute stores the time of the last closing
  # and is preserved when the issue is reopened.
  def update_closed_on
    if closing? || (new_record? && closed?)
      self.closed_on = updated_on
    end
  end

  # Saves the changes in a Journal
  # Called after_save
  def create_journal
    if @current_journal
      # attributes changes
      if @attributes_before_change
        (Issue.column_names - %w(id root_id lft rgt lock_version created_on updated_on closed_on)).each {|c|
          before = @attributes_before_change[c]
          after = send(c)
          next if before == after || (before.blank? && after.blank?)
          @current_journal.details << JournalDetail.new(:property => 'attr',
                                                        :prop_key => c,
                                                        :old_value => before,
                                                        :value => after)
        }
      end
      if @custom_values_before_change
        # custom fields changes
        custom_field_values.each {|c|
          before = @custom_values_before_change[c.custom_field_id]
          after = c.value
          next if before == after || (before.blank? && after.blank?)
          
          if before.is_a?(Array) || after.is_a?(Array)
            before = [before] unless before.is_a?(Array)
            after = [after] unless after.is_a?(Array)
            
            # values removed
            (before - after).reject(&:blank?).each do |value|
              @current_journal.details << JournalDetail.new(:property => 'cf',
                                                            :prop_key => c.custom_field_id,
                                                            :old_value => value,
                                                            :value => nil)
            end
            # values added
            (after - before).reject(&:blank?).each do |value|
              @current_journal.details << JournalDetail.new(:property => 'cf',
                                                            :prop_key => c.custom_field_id,
                                                            :old_value => nil,
                                                            :value => value)
            end
          else
            @current_journal.details << JournalDetail.new(:property => 'cf',
                                                          :prop_key => c.custom_field_id,
                                                          :old_value => before,
                                                          :value => after)
          end
        }
      end
      @current_journal.save
      # reset current journal
      init_journal @current_journal.user, @current_journal.notes
    end
  end

  def send_notification
    if Setting.notified_events.include?('issue_added')
      Mailer.deliver_issue_add(self)
    end
  end

  # Stores the previous assignee so we can still have access
  # to it during after_save callbacks (assigned_to_id_was is reset)
  def set_assigned_to_was
    @previous_assigned_to_id = assigned_to_id_was
  end

  # Clears the previous assignee at the end of after_save callbacks
  def clear_assigned_to_was
    @assigned_to_was = nil
    @previous_assigned_to_id = nil
  end

  # Query generator for selecting groups of issue counts for a project
  # based on specific criteria
  #
  # Options
  # * project - Project to search in.
  # * field - String. Issue field to key off of in the grouping.
  # * joins - String. The table name to join against.
  def self.count_and_group_by(options)
    project = options.delete(:project)
    select_field = options.delete(:field)
    joins = options.delete(:joins)

    where = "#{Issue.table_name}.#{select_field}=j.id"

    ActiveRecord::Base.connection.select_all("select    s.id as status_id, 
                                                s.is_closed as closed, 
                                                j.id as #{select_field},
                                                count(#{Issue.table_name}.id) as total 
                                              from 
                                                  #{Issue.table_name}, #{Project.table_name}, #{IssueStatus.table_name} s, #{joins} j
                                              where 
                                                #{Issue.table_name}.status_id=s.id 
                                                and #{where}
                                                and #{Issue.table_name}.project_id=#{Project.table_name}.id
                                                and #{visible_condition(User.current, :project => project)}
                                              group by s.id, s.is_closed, j.id")
  end
end
