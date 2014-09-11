class AddEnumerationsPosition < ActiveRecord::Migration
  def self.up
    add_column(:enumerations, :position, :integer, :default => 1) unless Enumeration.column_names.include?('position')
    Enumeration.all.group_by(&:opt).each do |opt, enums|
      enums.each_with_index do |enum, i|
        # do not call model callbacks
        Enumeration.update_all "position = #{i+1}", {:id => enum.id}
      end
    end
  end

  def self.down
    remove_column :enumerations, :position
  end
end
