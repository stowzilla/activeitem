# DynamoRecord

ActiveRecord-like ORM for AWS DynamoDB.

## Installation

```ruby
gem 'dynamorecord'
```

## Configuration

```ruby
DynamoRecord.configure do |config|
  config.table_prefix = 'myapp'
  config.environment = 'production'
  config.logger = Rails.logger # or any Logger-compatible object
end
```

Table names are generated as `{prefix}-{environment}-{model-name-pluralized}`.

## Usage

```ruby
class User < DynamoRecord::Base
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
class Post < DynamoRecord::Base
  belongs_to :user
  has_many :comments, foreign_key: 'post_id', index: 'PostIndex'
end
```

### Transactions

```ruby
DynamoRecord::Base.transaction do |txn|
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
class Customer < DynamoRecord::Base
  attr_accessor :street, :city, :state, :zip_code

  composed_of :address, class_name: 'Address', mapping: {
    street: :street, city: :city, state: :state, zip_code: :zip_code
  }
end
```

## License

MIT
