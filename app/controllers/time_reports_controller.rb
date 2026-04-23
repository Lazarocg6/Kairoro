class TimeReportsController < ApplicationController
  DEFAULT_CHART_COLOR = "#6471eb".freeze

  def index
    @period_type = params[:period_type]&.to_sym || :this_month
    @start_date, @end_date = resolve_range(@period_type)
    @period = Period.custom(start_date: @start_date, end_date: @end_date)

    @previous_period = build_previous_period(@period)

    @root_categories = Current.family.time_categories.roots.alphabetically.includes(:subcategories)
    @selected_category = resolve_selected_category

    blocks_scope = Current.family.time_blocks.for_user(Current.user)

    @current_blocks  = scope_blocks(blocks_scope.in_period(@period)).includes(time_category: :parent).to_a
    @previous_blocks = scope_blocks(blocks_scope.in_period(@previous_period)).includes(time_category: :parent).to_a

    @current_totals  = TimeBlock.aggregate_by_category(@current_blocks)
    @previous_totals = TimeBlock.aggregate_by_category(@previous_blocks)

    @total_current_minutes  = @current_totals.values.sum { |r| r[:minutes] }
    @total_previous_minutes = @previous_totals.values.sum { |r| r[:minutes] }

    @days_in_period = [ (@end_date - @start_date).to_i + 1, 1 ].max

    @pie_segments  = build_pie_segments(@current_totals, @selected_category)
    @sankey_data   = build_sankey_data(@current_totals, @selected_category)
    @category_rows = build_category_comparison_rows(@current_totals, @previous_totals, @selected_category)
    @chart_data    = build_chart_data(@current_blocks, @start_date, @end_date, @selected_category)

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

    # Only root categories are shown in the dropdown; selecting one filters the
    # report to that root and its subcategories.
    def resolve_selected_category
      id = params[:time_category_id]
      return nil if id.blank?
      Current.family.time_categories.roots.includes(:subcategories).find_by(id: id)
    end

    def scope_blocks(scope)
      return scope unless @selected_category

      category_ids = [ @selected_category.id ] + @selected_category.subcategories.pluck(:id)
      scope.where(time_category_id: category_ids)
    end

    # Pie / donut segments.
    # - No category selected: one segment per root category.
    # - Root with subcategories selected: one segment per subcategory, plus a
    #   "Direct" segment for time logged on the root itself.
    # - Root without subcategories: a single segment for the root.
    def build_pie_segments(totals, selected)
      if selected&.subcategories&.any?
        root = totals.values.find { |r| r[:id] == selected.id }
        return [] if root.nil? || root[:minutes].zero?

        subs = root[:subcategories].values.reject { |s| s[:minutes].zero? }.sort_by { |s| -s[:minutes] }
        leftover = root[:minutes] - subs.sum { |s| s[:minutes] }

        segments = subs.map do |s|
          { id: "sub_#{s[:id]}", color: s[:color], amount: s[:minutes], name: s[:name] }
        end

        if leftover.positive?
          segments << {
            id: "direct_#{root[:id]}",
            color: root[:color],
            amount: leftover,
            name: I18n.t("time_reports.sankey.direct", default: "Direct")
          }
        end

        segments
      else
        totals.values
          .reject { |r| r[:minutes].zero? }
          .sort_by { |r| -r[:minutes] }
          .map { |row| { id: row[:id] || "uncategorized", color: row[:color], amount: row[:minutes], name: row[:name] } }
      end
    end

    # Sankey: Time -> root category -> sub-categories, or (if a root is
    # selected) Root -> sub-categories directly.
    def build_sankey_data(totals, selected)
      if selected&.subcategories&.any?
        build_sankey_for_category(totals, selected)
      else
        build_sankey_all_categories(totals)
      end
    end

    def build_sankey_all_categories(totals)
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

        subs = root[:subcategories].values.sort_by { |s| -s[:minutes] }
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

      nodes.each { |n| n[:percentage] = (n[:value].to_f / total_minutes * 100).round(1) }

      { nodes: nodes, links: links, currency_symbol: "" }
    end

    def build_sankey_for_category(totals, selected)
      root = totals.values.find { |r| r[:id] == selected.id }
      return { nodes: [], links: [], currency_symbol: "" } if root.nil? || root[:minutes].zero?

      total_minutes = root[:minutes]
      nodes = [ { name: root[:name], value: root[:minutes].to_f.round(2), percentage: 100.0, color: root[:color] } ]
      links = []
      root_idx = 0

      subs = root[:subcategories].values.reject { |s| s[:minutes].zero? }.sort_by { |s| -s[:minutes] }
      leftover = root[:minutes] - subs.sum { |s| s[:minutes] }

      subs.each do |sub|
        pct = (sub[:minutes].to_f / total_minutes * 100).round(1)
        sub_idx = nodes.size
        nodes << { name: sub[:name], value: sub[:minutes].to_f.round(2), percentage: pct, color: sub[:color] }
        links << { source: root_idx, target: sub_idx, value: sub[:minutes], color: sub[:color], percentage: pct }
      end

      if leftover.positive? && subs.any?
        pct = (leftover.to_f / total_minutes * 100).round(1)
        direct_idx = nodes.size
        nodes << {
          name: I18n.t("time_reports.sankey.direct", default: "Direct"),
          value: leftover.to_f.round(2),
          percentage: pct,
          color: root[:color]
        }
        links << { source: root_idx, target: direct_idx, value: leftover, color: root[:color], percentage: pct }
      end

      { nodes: nodes, links: links, currency_symbol: "" }
    end

    def build_category_comparison_rows(current, previous, selected)
      if selected&.subcategories&.any?
        build_subcategory_comparison_rows(current, previous, selected)
      else
        ids = (current.keys + previous.keys).uniq
        ids.map do |key|
          curr = current[key]
          prev = previous[key]
          source = curr || prev

          current_minutes  = curr&.dig(:minutes) || 0
          previous_minutes = prev&.dig(:minutes) || 0

          comparison_row(
            id: source[:id] || "uncategorized",
            name: source[:name],
            color: source[:color],
            icon: source[:icon],
            current_minutes: current_minutes,
            previous_minutes: previous_minutes
          )
        end.sort_by { |row| -row[:current_minutes] }
      end
    end

    def build_subcategory_comparison_rows(current, previous, selected)
      curr_root = current[selected.id]
      prev_root = previous[selected.id]

      sub_ids = (
        (curr_root&.dig(:subcategories)&.keys || []) +
        (prev_root&.dig(:subcategories)&.keys || [])
      ).uniq

      rows = sub_ids.map do |sub_id|
        curr_sub = curr_root&.dig(:subcategories, sub_id)
        prev_sub = prev_root&.dig(:subcategories, sub_id)
        source = curr_sub || prev_sub

        comparison_row(
          id: source[:id],
          name: source[:name],
          color: source[:color],
          icon: source[:icon],
          current_minutes: curr_sub&.dig(:minutes) || 0,
          previous_minutes: prev_sub&.dig(:minutes) || 0
        )
      end

      curr_direct = (curr_root&.dig(:minutes) || 0) - (curr_root&.dig(:subcategories)&.values&.sum { |s| s[:minutes] } || 0)
      prev_direct = (prev_root&.dig(:minutes) || 0) - (prev_root&.dig(:subcategories)&.values&.sum { |s| s[:minutes] } || 0)

      if curr_direct.positive? || prev_direct.positive?
        rows << comparison_row(
          id: "direct",
          name: I18n.t("time_reports.sankey.direct", default: "Direct"),
          color: selected.color,
          icon: selected.lucide_icon,
          current_minutes: curr_direct,
          previous_minutes: prev_direct
        )
      end

      rows.sort_by { |row| -row[:current_minutes] }
    end

    def comparison_row(id:, name:, color:, icon:, current_minutes:, previous_minutes:)
      delta = current_minutes - previous_minutes
      percent_change =
        if previous_minutes.zero?
          current_minutes.zero? ? 0 : 100.0
        else
          (((current_minutes - previous_minutes) / previous_minutes.to_f) * 100).round(1)
        end

      {
        id: id,
        name: name,
        color: color,
        icon: icon,
        current_minutes: current_minutes,
        previous_minutes: previous_minutes,
        delta: delta,
        percent_change: percent_change
      }
    end

    # Produces the data payload consumed by the `time-series-chart` Stimulus
    # controller. Each point carries its own trend metadata so tooltips render
    # richly without extra client-side logic.
    def build_chart_data(blocks, start_date, end_date, selected)
      per_day = Hash.new(0)
      blocks.each { |b| per_day[b.started_at.to_date] += b.duration_minutes }

      color = selected&.color || DEFAULT_CHART_COLOR

      values = []
      prev_minutes = 0

      (start_date..end_date).each do |date|
        minutes = per_day[date]
        diff = minutes - prev_minutes
        percent = if prev_minutes.zero?
          minutes.zero? ? 0.0 : 100.0
        else
          ((diff.to_f / prev_minutes) * 100).round(1)
        end

        values << {
          date: date.to_s,
          date_formatted: I18n.l(date, format: :long),
          value: minutes,
          trend: {
            color: color,
            value: diff,
            previous: { amount: prev_minutes, formatted: helpers.format_minutes(prev_minutes) },
            current:  { amount: minutes, formatted: helpers.format_minutes(minutes) },
            percent_formatted: "#{percent}%"
          }
        }

        prev_minutes = minutes
      end

      { values: values, trend: { color: color } }
    end
end
