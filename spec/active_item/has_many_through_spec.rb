# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'has_many :through' do
  let(:dynamo_client) { @dynamo_client }

  let(:author_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-authors"
      attr_accessor :name

      has_many :authorings, class_name: 'Authoring', foreign_key: 'author_id', index: 'AuthorIndex'
      has_many :books, through: :authorings

      def self.name
        'Author'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  let(:book_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-books"
      attr_accessor :title

      has_many :authorings, class_name: 'Authoring', foreign_key: 'book_id', index: 'BookIndex'
      has_many :authors, through: :authorings

      def self.name
        'Book'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  let(:authoring_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-authorings"
      attr_accessor :book_id, :author_id

      belongs_to :book, class_name: 'Book', foreign_key: 'book_id'
      belongs_to :author, class_name: 'Author', foreign_key: 'author_id'

      indexes(
        'BookIndex' => { partition_key: 'bookId' },
        'AuthorIndex' => { partition_key: 'authorId' }
      )

      def self.name
        'Authoring'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  before do
    stub_const('Author', author_class)
    stub_const('Book', book_class)
    stub_const('Authoring', authoring_class)
  end

  describe 'basic resolution' do
    it 'resolves through association with 2 queries' do
      author1 = Author.create!(name: 'Hemingway')
      author2 = Author.create!(name: 'Fitzgerald')
      book = Book.create!(title: 'The Sun Also Rises')

      Authoring.create!(book_id: book.id, author_id: author1.id)
      Authoring.create!(book_id: book.id, author_id: author2.id)

      # book.authors should resolve via authorings
      authors = book.authors.to_a
      expect(authors.length).to eq(2)
      expect(authors.map(&:name)).to contain_exactly('Hemingway', 'Fitzgerald')
    end

    it 'resolves the inverse direction' do
      author = Author.create!(name: 'Hemingway')
      book1 = Book.create!(title: 'The Sun Also Rises')
      book2 = Book.create!(title: 'A Farewell to Arms')

      Authoring.create!(book_id: book1.id, author_id: author.id)
      Authoring.create!(book_id: book2.id, author_id: author.id)

      books = author.books.to_a
      expect(books.length).to eq(2)
      expect(books.map(&:title)).to contain_exactly('The Sun Also Rises', 'A Farewell to Arms')
    end

    it 'returns empty when no join records exist' do
      book = Book.create!(title: 'Orphan Book')
      expect(book.authors.to_a).to be_empty
    end

    it 'provides _count method' do
      author = Author.create!(name: 'Hemingway')
      book = Book.create!(title: 'The Sun Also Rises')
      Authoring.create!(book_id: book.id, author_id: author.id)

      expect(book.authors_count).to eq(1)
    end
  end

  describe 'source option' do
    let(:tagged_book_class) do
      Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-books"
        attr_accessor :title

        has_many :authorings, class_name: 'Authoring', foreign_key: 'book_id', index: 'BookIndex'
        has_many :writers, through: :authorings, source: :author, class_name: 'Author'

        def self.name
          'Book'
        end
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    it 'uses source to determine foreign key on join model' do
      stub_const('Book', tagged_book_class)

      author = Author.create!(name: 'Hemingway')
      book = tagged_book_class.create!(title: 'The Sun Also Rises')
      Authoring.create!(book_id: book.id, author_id: author.id)

      writers = book.writers.to_a
      expect(writers.length).to eq(1)
      expect(writers.first.name).to eq('Hemingway')
    end
  end

  describe 'preloading with includes' do
    it 'eager-loads through associations efficiently' do
      author1 = Author.create!(name: 'Hemingway')
      author2 = Author.create!(name: 'Fitzgerald')
      book1 = Book.create!(title: 'The Sun Also Rises')
      book2 = Book.create!(title: 'The Great Gatsby')

      Authoring.create!(book_id: book1.id, author_id: author1.id)
      Authoring.create!(book_id: book2.id, author_id: author2.id)
      Authoring.create!(book_id: book1.id, author_id: author2.id)

      books = Book.includes(:authors).all.to_a
      expect(books.length).to eq(2)

      sun = books.find { |b| b.title == 'The Sun Also Rises' }
      gatsby = books.find { |b| b.title == 'The Great Gatsby' }

      expect(sun.authors.to_a.map(&:name)).to contain_exactly('Hemingway', 'Fitzgerald')
      expect(gatsby.authors.to_a.map(&:name)).to eq(['Fitzgerald'])
    end

    it 'preloads counts for through associations' do
      author = Author.create!(name: 'Hemingway')
      book1 = Book.create!(title: 'Book One')
      Book.create!(title: 'Book Two')

      Authoring.create!(book_id: book1.id, author_id: author.id)

      books = Book.includes(authors: :count).all.to_a

      b1 = books.find { |b| b.title == 'Book One' }
      b2 = books.find { |b| b.title == 'Book Two' }

      expect(b1.authors_count).to eq(1)
      expect(b2.authors_count).to eq(0)
    end
  end

  describe 'index auto-detection' do
    it 'works without explicit index: on has_many when join model has indexes()' do
      # The has_many :authorings on Book has explicit index: 'BookIndex'
      # But even without it, detect_index_for_conditions would pick it up
      # from Authoring.indexes declaration
      book = Book.create!(title: 'Test')
      author = Author.create!(name: 'Author')
      Authoring.create!(book_id: book.id, author_id: author.id)

      # This exercises the full path: has_many → load_has_many_association → Relation → query
      authorings = book.authorings.to_a
      expect(authorings.length).to eq(1)
      expect(authorings.first.author_id).to eq(author.id)
    end

    context 'without explicit index on has_many' do
      let(:implicit_book_class) do
        Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-books"
          attr_accessor :title

          # No index: specified — relies on Authoring.indexes for auto-detection
          has_many :authorings, class_name: 'Authoring', foreign_key: 'book_id'
          has_many :authors, through: :authorings

          def self.name
            'Book'
          end
        end.tap { |klass| klass.dynamodb = dynamo_client }
      end

      it 'auto-detects index from join model indexes() declaration' do
        stub_const('Book', implicit_book_class)

        book = implicit_book_class.create!(title: 'Auto-Index Test')
        author = Author.create!(name: 'Writer')
        Authoring.create!(book_id: book.id, author_id: author.id)

        authors = book.authors.to_a
        expect(authors.length).to eq(1)
        expect(authors.first.name).to eq('Writer')
      end
    end
  end
end
