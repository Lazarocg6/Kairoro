class TimeCategory < ApplicationRecord
  belongs_to :family

  has_many :time_blocks, dependent: :nullify
  has_many :subcategories, class_name: "TimeCategory", foreign_key: :parent_id, dependent: :nullify
  belongs_to :parent, class_name: "TimeCategory", optional: true

  validates :name, :color, :lucide_icon, :family, presence: true
  validates :color, format: { with: /\A#[0-9A-Fa-f]{6}\z/ }
  validates :name, uniqueness: { scope: :family_id }

  validate :category_level_limit

  before_save :inherit_color_from_parent

  scope :alphabetically, -> { order(:name) }
  scope :roots, -> { where(parent_id: nil) }

  COLORS = %w[#e99537 #4da568 #6471eb #db5a54 #df4e92 #c44fe9 #eb5429 #61c9ea #805dee #6ad28a].freeze
  UNCATEGORIZED_COLOR = "#737373".freeze

  class Group
    attr_reader :category, :subcategories

    delegate :name, :color, to: :category

    def self.for(categories)
      categories.select { |c| c.parent_id.nil? }.map do |c|
        new(c, c.subcategories)
      end
    end

    def initialize(category, subcategories = nil)
      @category = category
      @subcategories = subcategories || []
    end
  end

  class << self
    # Icon codes reused from Category so the picker stays consistent
    def icon_codes
      Category.icon_codes
    end

    def uncategorized
      new(
        name: I18n.t("time_categories.uncategorized", default: "Uncategorized"),
        color: UNCATEGORIZED_COLOR,
        lucide_icon: "circle-dashed"
      )
    end

    def bootstrap!(family)
      default_categories.each do |name, color, icon|
        family.time_categories.find_or_create_by!(name: name) do |c|
          c.color = color
          c.lucide_icon = icon
        end
      end
    end

    private
      def default_categories
        [
          [ "Work",          "#6471eb", "briefcase" ],
          [ "Deep Work",     "#4da568", "brain" ],
          [ "Meetings",      "#61c9ea", "users" ],
          [ "Learning",      "#805dee", "graduation-cap" ],
          [ "Reading",       "#c44fe9", "book-open" ],
          [ "Exercise",      "#10b981", "dumbbell" ],
          [ "Sleep",         "#475569", "bed-single" ],
          [ "Personal Care", "#14b8a6", "scissors" ],
          [ "Chores",        "#d97706", "home" ],
          [ "Social",        "#db5a54", "heart" ],
          [ "Leisure",       "#a855f7", "drama" ],
          [ "Commute",       "#0ea5e9", "bus" ]
        ]
      end
  end

  def parent?
    subcategories.any?
  end

  def subcategory?
    parent.present?
  end

  def name_with_parent
    subcategory? ? "#{parent.name} > #{name}" : name
  end

  # Replace this category on all child time blocks with `replacement` then destroy self.
  def replace_and_destroy!(replacement)
    transaction do
      time_blocks.update_all(time_category_id: replacement&.id)
      destroy!
    end
  end

  def inherit_color_from_parent
    self.color = parent.color if subcategory?
  end

  private
    def category_level_limit
      if (subcategory? && parent.subcategory?) || (parent? && subcategory?)
        errors.add(:parent, "can't have more than 2 levels of subcategories")
      end
    end
end
