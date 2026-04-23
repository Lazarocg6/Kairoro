class TimeBlock < ApplicationRecord
  belongs_to :family
  belongs_to :user
  belongs_to :time_category, optional: true

  validates :started_at, :ended_at, presence: true
  validate  :ended_after_started
  validate  :reasonable_duration

  scope :chronological,     -> { order(started_at: :desc) }
  scope :in_period,         ->(period) { where(started_at: period.date_range.begin.beginning_of_day..period.date_range.end.end_of_day) }
  scope :between,           ->(range)  { where(started_at: range) }
  scope :for_user,          ->(user)   { where(user_id: user.id) }

  MAX_DURATION_MINUTES = 24 * 60

  # Duration in minutes (integer) from started_at/ended_at
  def duration_minutes
    return 0 unless started_at && ended_at
    ((ended_at - started_at) / 60).round
  end

  def duration_hours
    duration_minutes / 60.0
  end

  # Human-friendly duration, e.g. "1h 30m" or "45m"
  def duration_label
    mins = duration_minutes
    h = mins / 60
    m = mins % 60
    if h.positive? && m.positive?
      "#{h}h #{m}m"
    elsif h.positive?
      "#{h}h"
    else
      "#{m}m"
    end
  end

  def root_time_category
    time_category&.parent || time_category
  end

  class << self
    # Fetches blocks in the period with time_category + parent eager loaded.
    def for_family_period(family, period, user: nil)
      scope = family.time_blocks.in_period(period).includes(time_category: :parent)
      scope = scope.for_user(user) if user
      scope
    end

    # Total minutes grouped by root category id (falls back to :uncategorized symbol).
    # Returns { key => { name:, color:, icon:, minutes:, subcategories: { sub_id => { name:, color:, icon:, minutes: } } } }
    def aggregate_by_category(blocks)
      result = {}
      blocks.each do |block|
        cat = block.time_category
        root = cat&.parent || cat

        key = root&.id || :uncategorized
        result[key] ||= {
          id: root&.id,
          name: root&.name || I18n.t("time_categories.uncategorized", default: "Uncategorized"),
          color: root&.color || TimeCategory::UNCATEGORIZED_COLOR,
          icon: root&.lucide_icon || "circle-dashed",
          minutes: 0,
          subcategories: {}
        }
        result[key][:minutes] += block.duration_minutes

        if cat && cat.parent_id.present?
          sub = cat
          result[key][:subcategories][sub.id] ||= {
            id: sub.id,
            name: sub.name,
            color: sub.color,
            icon: sub.lucide_icon,
            minutes: 0
          }
          result[key][:subcategories][sub.id][:minutes] += block.duration_minutes
        end
      end
      result
    end
  end

  private
    def ended_after_started
      return unless started_at && ended_at
      errors.add(:ended_at, :must_be_after_started_at) if ended_at <= started_at
    end

    def reasonable_duration
      return unless started_at && ended_at
      if (ended_at - started_at) / 60 > MAX_DURATION_MINUTES
        errors.add(:ended_at, :too_long)
      end
    end
end
