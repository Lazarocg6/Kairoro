module TimeTrackingHelper
  # Formats an integer number of minutes into a concise "Xh Ym" label.
  def format_minutes(minutes)
    minutes = minutes.to_i
    return "0m" if minutes.zero?

    sign = minutes.negative? ? "-" : ""
    minutes = minutes.abs

    h = minutes / 60
    m = minutes % 60

    if h.positive? && m.positive?
      "#{sign}#{h}h #{m}m"
    elsif h.positive?
      "#{sign}#{h}h"
    else
      "#{sign}#{m}m"
    end
  end

  # Formats a decimal number of hours into "X.XXh" label.
  def format_hours(minutes, precision: 1)
    hours = minutes.to_f / 60.0
    "#{format("%.#{precision}f", hours)}h"
  end

  # A small swatch using the category color and icon, mirroring finance categories.
  def time_category_avatar(time_category, size: "md")
    pixel = size == "sm" ? "w-6 h-6" : "w-8 h-8"
    icon_size = size == "sm" ? "sm" : "md"
    color = time_category&.color || TimeCategory::UNCATEGORIZED_COLOR
    lucide = time_category&.lucide_icon || "circle-dashed"
    content_tag :span,
                icon(lucide, size: icon_size, color: "current"),
                class: "#{pixel} flex items-center justify-center rounded-full shrink-0",
                style: "background-color: color-mix(in oklab, #{color} 12%, transparent); color: #{color}"
  end
end
