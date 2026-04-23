class TimeReportsController < ApplicationController
  def index
    @period_type = params[:period_type]&.to_sym || :this_month
    @start_date, @end_date = resolve_range(@period_type)
    @period = Period.custom(start_date: @start_date, end_date: @end_date)

    @previous_period = build_previous_period(@period)

    blocks_scope = Current.family.time_blocks.for_user(Current.user)

    @current_blocks  = blocks_scope.in_period(@period).includes(time_category: :parent).to_a
    @previous_blocks = blocks_scope.in_period(@previous_period).includes(time_category: :parent).to_a

    @current_totals  = TimeBlock.aggregate_by_category(@current_blocks)
    @previous_totals = TimeBlock.aggregate_by_category(@previous_blocks)

    @total_current_minutes  = @current_totals.values.sum { |r| r[:minutes] }
    @total_previous_minutes = @previous_totals.values.sum { |r| r[:minutes] }

    @days_in_period = [ (@end_date - @start_date).to_i + 1, 1 ].max

    @pie_segments = build_pie_segments(@current_totals)
    @sankey_data  = build_sankey_data(@current_totals)
    @category_rows = build_category_comparison_rows(@current_totals, @previous_totals)
    @daily_series  = build_daily_series(@current_blocks, @start_date, @end_date)

    @breadcrumbs = [ [ "Home", root_path ], [ t("time_reports.index.title"), nil ] ]
  end

  private
    def resolve_range(period_type)
      today = Date.current
      case period_type
      when :this_week
        [ today.beginning_of_week, today.end_of_week ]
      when :last_week
        wk = 1.week.ago.to_date
        [ wk.beginning_of_week, wk.end_of_week ]
      when :this_month
        [ today.beginning_of_month, today.end_of_month ]
      when :last_month
        month = 1.month.ago.to_date
        [ month.beginning_of_month, month.end_of_month ]
      when :last_30_days
        [ today - 29.days, today ]
      when :last_90_days
        [ today - 89.days, today ]
      when :ytd
        [ today.beginning_of_year, today ]
      when :custom
        start_date = parse_date(params[:start_date]) || today.beginning_of_month
        end_date   = parse_date(params[:end_date])   || today
        start_date, end_date = end_date, start_date if start_date > end_date
        [ start_date, end_date ]
      else
        [ today.beginning_of_month, today.end_of_month ]
      end
    end

    def parse_date(value)
      return nil if value.blank?
      Date.parse(value)
    rescue Date::Error
      nil
    end

    def build_previous_period(period)
      duration = (period.date_range.end - period.date_range.begin).to_i
      previous_end = period.date_range.begin - 1.day
      previous_start = previous_end - duration.days
      Period.custom(start_date: previous_start, end_date: previous_end)
    end

    # Pie: one segment per root category + optional uncategorized
    def build_pie_segments(totals)
      sorted = totals.values.reject { |r| r[:minutes].zero? }.sort_by { |r| -r[:minutes] }
      sorted.map do |row|
        { id: row[:id] || "uncategorized", color: row[:color], amount: row[:minutes], name: row[:name] }
      end
    end

    # Sankey: Time -> root category -> sub-categories
    def build_sankey_data(totals)
      nodes = []
      links = []
      node_indices = {}

      add_node = ->(key, name, value, color) {
        node_indices[key] ||= begin
          nodes << { name: name, value: value.to_f.round(2), percentage: 0, color: color }
          nodes.size - 1
        end
      }

      total_minutes = totals.values.sum { |r| r[:minutes] }
      return { nodes: [], links: [], currency_symbol: "" } if total_minutes.zero?

      time_idx = add_node.call(:time, I18n.t("time_reports.sankey.center", default: "Time"), total_minutes, "var(--color-success)")

      totals.values.sort_by { |r| -r[:minutes] }.each do |root|
        next if root[:minutes].zero?

        root_key = [ :root, root[:id] || :uncategorized ]
        root_idx = add_node.call(root_key, root[:name], root[:minutes], root[:color])
        percentage = (root[:minutes].to_f / total_minutes * 100).round(1)
        links << { source: time_idx, target: root_idx, value: root[:minutes], color: root[:color], percentage: percentage }

        # Subcategories as further children
        subs = root[:subcategories].values.sort_by { |s| -s[:minutes] }
        # Explicit parent-only minutes (blocks assigned directly to the root category)
        leftover = root[:minutes] - subs.sum { |s| s[:minutes] }

        subs.each do |sub|
          sub_key = [ :sub, sub[:id] ]
          sub_idx = add_node.call(sub_key, sub[:name], sub[:minutes], sub[:color])
          sub_pct = (sub[:minutes].to_f / total_minutes * 100).round(1)
          links << { source: root_idx, target: sub_idx, value: sub[:minutes], color: sub[:color], percentage: sub_pct }
        end

        if leftover.positive? && subs.any?
          direct_key = [ :direct, root[:id] ]
          direct_idx = add_node.call(
            direct_key,
            I18n.t("time_reports.sankey.direct", default: "Direct"),
            leftover,
            root[:color]
          )
          pct = (leftover.to_f / total_minutes * 100).round(1)
          links << { source: root_idx, target: direct_idx, value: leftover, color: root[:color], percentage: pct }
        end
      end

      # Compute percentages for node values
      nodes.each { |n| n[:percentage] = (n[:value].to_f / total_minutes * 100).round(1) }

      { nodes: nodes, links: links, currency_symbol: "" }
    end

    def build_category_comparison_rows(current, previous)
      ids = (current.keys + previous.keys).uniq
      ids.map do |key|
        curr = current[key]
        prev = previous[key]
        source = curr || prev

        current_minutes  = curr&.dig(:minutes) || 0
        previous_minutes = prev&.dig(:minutes) || 0
        delta = current_minutes - previous_minutes

        percent_change =
          if previous_minutes.zero?
            current_minutes.zero? ? 0 : 100.0
          else
            (((current_minutes - previous_minutes) / previous_minutes.to_f) * 100).round(1)
          end

        {
          id: source[:id] || "uncategorized",
          name: source[:name],
          color: source[:color],
          icon: source[:icon],
          current_minutes: current_minutes,
          previous_minutes: previous_minutes,
          delta: delta,
          percent_change: percent_change
        }
      end.sort_by { |row| -row[:current_minutes] }
    end

    # Daily series: [{ date:, minutes: }]
    def build_daily_series(blocks, start_date, end_date)
      per_day = Hash.new(0)
      blocks.each do |block|
        date = block.started_at.to_date
        per_day[date] += block.duration_minutes
      end

      (start_date..end_date).map do |date|
        { date: date, minutes: per_day[date] }
      end
    end
end
