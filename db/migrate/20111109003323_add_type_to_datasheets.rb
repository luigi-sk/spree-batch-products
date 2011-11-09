class AddTypeToDatasheets < ActiveRecord::Migration
  def self.up
    add_column :product_datasheets, :type, :string
    
  end

  def self.down
    remove_column :product_datasheets, :type
  end
end
