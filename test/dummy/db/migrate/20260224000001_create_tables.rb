class CreateTables < ActiveRecord::Migration[7.0]
  def change
    create_table :users do |t|
      t.string :email
      t.string :name
      t.string :password
      t.string :reset_password_token
      t.datetime :reset_password_sent_at
      t.timestamps null: false
    end

    create_table :forums do |t|
      t.string :name
      t.timestamps null: false
    end

    create_table :topics do |t|
      t.string :name
      t.references :forum
      t.references :user
      t.references :assigned_user
      t.boolean :private, default: false
      t.timestamps null: false
    end

    create_table :posts do |t|
      t.text :body
      t.text :raw_email
      t.references :topic
      t.references :user
      t.string :cc
      t.string :kind
      t.timestamps null: false
    end
  end
end
