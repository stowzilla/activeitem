# ActiveItem

ActiveRecord-like ORM for AWS DynamoDB.

## Installation

```ruby
gem 'activeitem'
```

To install with signature verification:

```bash
gem cert --add <(curl -Ls https://raw.githubusercontent.com/stowzilla/activeitem/master/certs/stowzilla.pem)
gem install activeitem -P MediumSecurity
```

## Configuration

```ruby
ActiveItem.configure do |config|
  config.table_prefix = 'myapp'
  config.environment = 'production'
  config.logger = Rails.logger # or any Logger-compatible object
end
```

Table names are generated as `{prefix}-{environment}-{model-name-pluralized}`.

## Usage

```ruby
class User < ActiveItem::Base
  self.primary_key = :user_id

  attr_accessor :email, :name, :status

  indexes(
    'EmailIndex' => { partition_key: 'email' },
    'StatusIndex' => { partition_key: 'status', sort_key: 'createdAt' }
  )

  validates :email, presence: true
  validates :email, uniqueness: true

  scope :active, -> { where(status: 'active') }

  before_create :set_defaults

  private

  def set_defaults
    self.status ||= 'active'
  end
end
```

### CRUD

```ruby
user = User.create!(email: 'alice@example.com', name: 'Alice')
user = User.find('user-123')
user.update(name: 'Alice Smith')
user.destroy
```

### Querying

```ruby
User.where(status: 'active', index: 'StatusIndex')
User.where(email: 'alice@example.com', index: 'EmailIndex').first
User.where.not(status: 'deleted')
User.all.limit(50)
User.count
User.exists?('user-123')
```

### Associations

```ruby
class Post < ActiveItem::Base
  belongs_to :user
  has_many :comments, foreign_key: 'post_id', index: 'PostIndex'
end
```

### Transactions

```ruby
ActiveItem::Base.transaction do |txn|
  txn.put(new_record)
  txn.update(existing_record)
  txn.delete(old_record)
end
```

### Pagination

```ruby
result = Post.where(user_id: id, index: 'UserIndex').page(cursor, per_page: 25)
result.items          # => [Post, Post, ...]
result.pagination_metadata # => { next_cursor: "...", has_more: true, per_page: 25 }
```

### Composed Of (Value Objects)

```ruby
class Customer < ActiveItem::Base
  attr_accessor :street, :city, :state, :zip_code

  composed_of :address, class_name: 'Address', mapping: {
    street: :street, city: :city, state: :state, zip_code: :zip_code
  }
end
```

### Custom Attribute Writers

Like ActiveRecord, you can override a generated writer to coerce or normalize a
value on assignment. Just route the assignment back through the generated
writer — call `super`, or use `write_attribute`. Both record the change for
dirty tracking, so `save` (and `update`) persist it. Assigning `@ivar` directly
bypasses dirty tracking and the change is silently dropped on update.

```ruby
class Article < ActiveItem::Base
  attr_accessor :tags, :payload

  # Coerce to an Array, Rails-style: override and call super.
  def tags=(value)
    super(Array(value))
  end

  # Or be explicit with write_attribute.
  def payload=(value)
    write_attribute(:payload, value.is_a?(String) ? value : JSON.generate(value))
  end
end
```

`read_attribute(:name)` is available too, for custom readers:

```ruby
def display_name
  read_attribute(:name).to_s.strip
end
```

## License

MIT
