class TimeReportsController < ApplicationController
  DEFAULT_CHART_COLOR = "#6471eb".freeze
  MAX_CHART_SERIES = 10
  OTHER_SERIES_COLOR = "#a3a3a3".freeze

  def index
    @period_type = params[:period_type]&.to_sym || :this_month
    @start_date, @end_date = resolve_range(@period_type)
    @period = Period.custom(start_date: @start_date, end_date: @end_date)

    @previous_period = build_previous_period(@period)

    @root_categories = Current.family.time_categories.roots.alphabetically.includes(:subcategories)
    @selected_category = resolve_selected_category

    blocks_scope = Current.family.time_blocks.for_user(Current.user)

    # Fetch unfiltered, then filter in Ruby so the evolution chart can render
    # per-category series even when a single category is highlighted.
    all_current_blocks  = blocks_scope.in_period(@period).includes(time_category: :parent).to_a
    all_previous_blocks = blocks_scope.in_period(@previous_period).includes(time_category: :parent).to_a

    @current_blocks  = filter_blocks_by_category(all_current_blocks)
    @previous_blocks = filter_blocks_by_category(all_previous_blocks)

    @current_totals  = TimeBlock.aggregate_by_category(@current_blocks)
    @previous_totals = TimeBlock.aggregate_by_category(@previous_blocks)

    # When a parent category is selected, all its subs share the parent's
    # color in the DB (see `TimeCategory#inherit_color_from_parent`). For the
    # report views we swap those colors for distinct lightness variants of
    # the parent's hue so each sub line/segment is readable. Only applied
    # when the dropdown is actually expanding into subs.
    @subcategory_color_map = build_subcategory_color_map(@selected_category)
    apply_subcategory_colors!(@current_totals,  @subcategory_color_map) if @subcategory_color_map.any?
    apply_subcategory_colors!(@previous_totals, @subcategory_color_map) if @subcategory_color_map.any?

    @total_current_minutes  = @current_totals.values.sum { |r| r[:minutes] }
    @total_previous_minutes = @previous_totals.values.sum { |r| r[:minutes] }

    @days_in_period = [ (@end_date - @start_date).to_i + 1, 1 ].max

    @pie_segments       = build_pie_segments(@current_totals, @selected_category)
    @sankey_data        = build_sankey_data(@current_totals, @selected_category)
    @category_rows      = build_category_comparison_rows(@current_totals, @previous_totals, @selected_category)
    @chart_series_data  = build_chart_series_data(all_current_blocks, @start_date, @end_date, @selected_category, @subcategory_color_map)

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

    def filter_blocks_by_category(blocks)
      return blocks unless @selected_category

      category_ids = [ @selected_category.id ] + @selected_category.subcategories.pluck(:id)
      blocks.select { |b| category_ids.include?(b.time_category_id) }
    end

    # Pie / donut segments.
    # - No category selected: one segment per root category.
    # - Root with subcategories selected: one segment per subcategory, plus an
    #   "Unsorted" segment for time logged directly on the root itself.
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
            name: I18n.t("time_reports.sankey.unsorted", default: "Unsorted")
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
            I18n.t("time_reports.sankey.unsorted", default: "Unsorted"),
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
          name: I18n.t("time_reports.sankey.unsorted", default: "Unsorted"),
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
          name: I18n.t("time_reports.sankey.unsorted", default: "Unsorted"),
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

    # Produces the multi-series payload consumed by the
    # `multi-line-time-chart` Stimulus controller.
    #
    # Behavior by selection state:
    # - No selection: one series per root category (the "Uncategorized" bucket
    #   appears if any blocks lack a category). All highlighted.
    # - Root without subcategories selected: one series per root category, only
    #   the selected root is highlighted (the rest render dimmed).
    # - Root *with* subcategories selected: the selected root's line is
    #   replaced by one series per subcategory (plus an "Unsorted" series for
    #   time logged directly on the root), all highlighted. The other root
    #   categories stay in place and render dimmed.
    def build_chart_series_data(blocks, start_date, end_date, selected, subcategory_colors = {})
      dates = (start_date..end_date).to_a
      expand_subs = selected&.subcategories&.any?

      series_map = {}

      blocks.each do |block|
        cat  = block.time_category
        root = cat&.parent || cat

        key, attrs = series_key_and_attrs(cat, root, selected, expand_subs, subcategory_colors)

        series_map[key] ||= attrs.merge(per_day: Hash.new(0))
        series_map[key][:per_day][block.started_at.to_date] += block.duration_minutes
      end

      series = series_map.values.map do |s|
        {
          id:          s[:id],
          name:        s[:name],
          color:       s[:color],
          total:       s[:per_day].values.sum,
          highlighted: s[:highlighted],
          values:      dates.map { |d| { date: d.to_s, minutes: s[:per_day][d] } }
        }
      end

      series.sort_by! { |s| -s[:total] }
      series = bucket_small_series(series, dates, selected)

      {
        start_date:            start_date.to_s,
        end_date:              end_date.to_s,
        highlighted_series_id: selected&.id,
        series:                series
      }
    end

    # Classifies a block into the right series bucket for the chart. Separated
    # from `build_chart_series_data` to keep its logic easy to follow.
    def series_key_and_attrs(cat, root, selected, expand_subs, subcategory_colors = {})
      if expand_subs && root&.id == selected.id
        if cat.id == root.id
          # Blocks logged directly on the parent (no subcategory picked) get
          # their own "Unsorted" series alongside the real sub-series.
          [
            [ :direct, root.id ],
            {
              id:          "direct_#{root.id}",
              name:        I18n.t("time_reports.sankey.unsorted", default: "Unsorted"),
              color:       root.color,
              highlighted: true
            }
          ]
        else
          [
            [ :sub, cat.id ],
            {
              id:          cat.id,
              name:        cat.name,
              color:       subcategory_colors[cat.id] || cat.color || TimeCategory::UNCATEGORIZED_COLOR,
              highlighted: true
            }
          ]
        end
      else
        [
          [ :root, root&.id || :uncategorized ],
          {
            id:          root&.id || "uncategorized",
            name:        root&.name || I18n.t("time_categories.uncategorized", default: "Uncategorized"),
            color:       root&.color || TimeCategory::UNCATEGORIZED_COLOR,
            highlighted: selected.nil? || (!expand_subs && selected.id == root&.id)
          }
        ]
      end
    end

    # Collapses the smallest series past MAX_CHART_SERIES into a single "Other"
    # line so the chart stays readable with many categories. Any series marked
    # `highlighted` is pinned visible first so the user's current focus never
    # silently disappears into the Other bucket. Remaining slots are filled by
    # the largest non-highlighted series; everything else is summed into Other.
    def bucket_small_series(series, dates, selected)
      return series if series.size <= MAX_CHART_SERIES

      pinned     = series.select { |s| s[:highlighted] }
      candidates = series - pinned

      if selected.nil?
        # No selection -> every series is "highlighted" by default, so fall
        # back to a simple top-N trim instead of forcing them all visible.
        pinned     = []
        candidates = series
      end

      slots_left = [ MAX_CHART_SERIES - pinned.size, 0 ].max
      visible    = pinned + candidates.first(slots_left)

      hidden = series - visible
      return visible if hidden.empty?

      per_day = Hash.new(0)
      hidden.each do |s|
        s[:values].each { |v| per_day[v[:date]] += v[:minutes] }
      end

      other_series = {
        id:          "other",
        name:        I18n.t("time_reports.index.other_categories", default: "Other"),
        color:       OTHER_SERIES_COLOR,
        total:       per_day.values.sum,
        highlighted: selected.nil?,
        values:      dates.map { |d| { date: d.to_s, minutes: per_day[d.to_s] } }
      }

      (visible + [ other_series ]).sort_by { |s| -s[:total] }
    end

    # Returns { sub_id => hex_color } for the selected parent's subcategories,
    # or an empty hash when no expansion is needed. Each sub gets a distinct
    # lightness variant of the parent's hue so subs look like siblings rather
    # than identical twins.
    def build_subcategory_color_map(selected)
      return {} unless selected&.subcategories&.any?

      # Stable order so colors don't reshuffle between requests.
      subs = selected.subcategories.order(:id).to_a
      shades = derive_shades(selected.color, subs.size)
      subs.each_with_index.each_with_object({}) do |(sub, i), map|
        map[sub.id] = shades[i]
      end
    end

    # Overwrites sub colors in the aggregate hash (produced by
    # `TimeBlock.aggregate_by_category`) with the derived variants.
    def apply_subcategory_colors!(totals, color_map)
      totals.each_value do |row|
        row[:subcategories]&.each_value do |sub|
          mapped = color_map[sub[:id]]
          sub[:color] = mapped if mapped
        end
      end
    end

    # Produces `count` hex colors derived from `base_hex`. Lightness, hue and
    # saturation are all nudged so each sub is clearly distinguishable while
    # still reading as part of the parent's palette.
    #
    # - Lightness spans a wide range (0.30..0.78) for strong contrast.
    # - Hue is shifted ±18° around the base for warm/cool siblings.
    # - Saturation dips slightly toward the bright end so lighter shades
    #   don't look washed-out.
    def derive_shades(base_hex, count)
      return [] if count.to_i.zero?

      h, s, _l = rgb_to_hsl(*hex_to_rgb(base_hex))

      min_l, max_l    = 0.30, 0.78
      hue_spread      = 36.0 / 360.0  # total range; ±18° around the base
      sat_spread      = 0.20          # total range around the base
      sat_floor       = 0.35
      sat_ceiling     = 0.95

      count.times.map do |i|
        t = count == 1 ? 0.5 : i / (count - 1).to_f
        new_l = min_l + (max_l - min_l) * t
        new_h = (h + hue_spread * (t - 0.5)) % 1.0
        new_s = (s + sat_spread * (0.5 - t)).clamp(sat_floor, sat_ceiling)
        rgb_to_hex(*hsl_to_rgb(new_h, new_s, new_l))
      end
    end

    def hex_to_rgb(hex)
      clean = hex.to_s.delete_prefix("#")
      [ clean[0..1], clean[2..3], clean[4..5] ].map { |c| c.to_i(16) }
    end

    def rgb_to_hex(r, g, b)
      format("#%02x%02x%02x", r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255))
    end

    def rgb_to_hsl(r, g, b)
      rn, gn, bn = r / 255.0, g / 255.0, b / 255.0
      max = [ rn, gn, bn ].max
      min = [ rn, gn, bn ].min
      l = (max + min) / 2.0

      if max == min
        return [ 0.0, 0.0, l ]
      end

      d = max - min
      s = l > 0.5 ? d / (2.0 - max - min) : d / (max + min)
      h =
        case max
        when rn then (gn - bn) / d + (gn < bn ? 6 : 0)
        when gn then (bn - rn) / d + 2
        else         (rn - gn) / d + 4
        end
      [ h / 6.0, s, l ]
    end

    def hsl_to_rgb(h, s, l)
      if s.zero?
        v = (l * 255).round
        return [ v, v, v ]
      end

      hue_to_rgb = ->(p, q, t) {
        t += 1 if t < 0
        t -= 1 if t > 1
        return p + (q - p) * 6 * t       if t < 1.0 / 6
        return q                         if t < 1.0 / 2
        return p + (q - p) * (2.0 / 3 - t) * 6 if t < 2.0 / 3
        p
      }

      q = l < 0.5 ? l * (1 + s) : l + s - l * s
      p = 2 * l - q
      [
        (hue_to_rgb.call(p, q, h + 1.0 / 3) * 255).round,
        (hue_to_rgb.call(p, q, h) * 255).round,
        (hue_to_rgb.call(p, q, h - 1.0 / 3) * 255).round
      ]
    end
end
