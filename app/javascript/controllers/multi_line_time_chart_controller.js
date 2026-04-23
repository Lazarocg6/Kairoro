import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";

// Renders a multi-line evolution chart where each line represents a root
// time category. When a single category is highlighted (via the dropdown on
// the reports page), its line is shown at full opacity with a thicker stroke
// while the rest are dimmed so it stands out but retains context.
export default class extends Controller {
  static values = {
    data: Object,
    strokeWidth: { type: Number, default: 2 },
  };

  _resizeObserver = null;

  connect() {
    this._install();
    document.addEventListener("turbo:load", this._reinstall);
    this._setupResizeObserver();
  }

  disconnect() {
    this._teardown();
    document.removeEventListener("turbo:load", this._reinstall);
    this._resizeObserver?.disconnect();
  }

  _reinstall = () => {
    this._teardown();
    this._install();
  };

  _setupResizeObserver() {
    this._resizeObserver = new ResizeObserver(() => this._reinstall());
    this._resizeObserver.observe(this.element);
  }

  _teardown() {
    d3.select(this.element).selectAll("*").remove();
    this._tooltip?.remove();
    this._tooltip = null;
  }

  _install() {
    const width = this.element.clientWidth;
    const height = this.element.clientHeight;

    if (width < 50 || height < 50) return;

    const data = this.dataValue || {};
    const series = (data.series || []).map((s) => ({
      ...s,
      values: (s.values || []).map((v) => ({
        date: d3.timeParse("%Y-%m-%d")(v.date),
        minutes: Number(v.minutes) || 0,
      })),
    }));

    if (series.length === 0) return;

    const allDates = series[0]?.values.map((v) => v.date) || [];
    if (allDates.length === 0) return;

    const margin = { top: 16, right: 16, bottom: 28, left: 40 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    const hasHighlight = Boolean(data.highlighted_series_id);

    const svg = d3
      .select(this.element)
      .append("svg")
      .attr("width", width)
      .attr("height", height);

    const g = svg
      .append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`);

    const x = d3.scaleTime().domain(d3.extent(allDates)).range([0, innerWidth]);

    const maxY = d3.max(series, (s) => d3.max(s.values, (v) => v.minutes)) || 0;
    const y = d3
      .scaleLinear()
      .domain([0, Math.max(maxY, 1)])
      .nice()
      .range([innerHeight, 0]);

    // X-axis: a few ticks, lightweight styling so the chart stays clean.
    const xAxis = d3
      .axisBottom(x)
      .ticks(Math.max(2, Math.min(6, Math.floor(innerWidth / 90))))
      .tickFormat(d3.timeFormat("%b %d"))
      .tickSizeOuter(0);

    g.append("g")
      .attr("transform", `translate(0,${innerHeight})`)
      .call(xAxis)
      .call((sel) => sel.select(".domain").attr("stroke", "var(--color-border)"))
      .call((sel) =>
        sel
          .selectAll("text")
          .attr("fill", "var(--color-secondary)")
          .style("font-size", "11px")
      )
      .call((sel) => sel.selectAll(".tick line").attr("stroke", "var(--color-border)"));

    const yAxis = d3
      .axisLeft(y)
      .ticks(4)
      .tickFormat((d) => this._formatMinutes(d))
      .tickSizeOuter(0)
      .tickSize(-innerWidth);

    g.append("g")
      .call(yAxis)
      .call((sel) => sel.select(".domain").remove())
      .call((sel) =>
        sel
          .selectAll("text")
          .attr("fill", "var(--color-secondary)")
          .style("font-size", "11px")
      )
      .call((sel) =>
        sel
          .selectAll(".tick line")
          .attr("stroke", "var(--color-border)")
          .attr("stroke-dasharray", "2,2")
      );

    const line = d3
      .line()
      .defined((d) => d.minutes !== null && d.minutes !== undefined)
      .x((d) => x(d.date))
      .y((d) => y(d.minutes))
      .curve(d3.curveMonotoneX);

    // Draw non-highlighted series first so the highlighted one stays on top.
    const sorted = [...series].sort((a, b) => {
      if (a.highlighted === b.highlighted) return b.total - a.total;
      return a.highlighted ? 1 : -1;
    });

    const seriesGroup = g.append("g").attr("class", "series-group");

    sorted.forEach((s) => {
      const isDim = hasHighlight && !s.highlighted;
      seriesGroup
        .append("path")
        .datum(s.values)
        .attr("fill", "none")
        .attr("stroke", s.color)
        .attr("stroke-width", isDim ? this.strokeWidthValue : this.strokeWidthValue + 1)
        .attr("opacity", isDim ? 0.18 : 1)
        .attr("d", line);
    });

    // Hover guide + tooltip wired to an invisible full-height overlay.
    const focusLine = g
      .append("line")
      .attr("stroke", "var(--color-border)")
      .attr("stroke-dasharray", "3,3")
      .attr("y1", 0)
      .attr("y2", innerHeight)
      .style("opacity", 0);

    const focusDots = g.append("g").attr("class", "focus-dots").style("opacity", 0);

    focusDots
      .selectAll("circle")
      .data(sorted)
      .enter()
      .append("circle")
      .attr("r", 3.5)
      .attr("fill", (d) => d.color)
      .attr("stroke", "var(--color-container)")
      .attr("stroke-width", 1.5);

    const tooltip = d3
      .select(document.body)
      .append("div")
      .attr(
        "class",
        "pointer-events-none fixed z-50 rounded-lg border border-secondary bg-container shadow-lg p-2 text-xs text-primary"
      )
      .style("opacity", 0)
      .style("min-width", "150px");
    this._tooltip = tooltip;

    g.append("rect")
      .attr("width", innerWidth)
      .attr("height", innerHeight)
      .attr("fill", "transparent")
      .on("mouseover", () => {
        focusLine.style("opacity", 1);
        focusDots.style("opacity", 1);
        tooltip.style("opacity", 1);
      })
      .on("mouseout", () => {
        focusLine.style("opacity", 0);
        focusDots.style("opacity", 0);
        tooltip.style("opacity", 0);
      })
      .on("mousemove", (event) => {
        const [mouseX] = d3.pointer(event);
        const date = x.invert(mouseX);

        // `allDates` is already an array of Date objects, so bisect directly
        // against it — using an accessor like `(d) => d.date` would return
        // `undefined` for every element and produce a garbage index, which
        // would freeze the focus dots at the wrong position.
        const i = d3.bisectLeft(allDates, date);
        const d0 = allDates[Math.max(0, i - 1)];
        const d1 = allDates[Math.min(allDates.length - 1, i)];
        const closest = date - d0 > d1 - date ? d1 : d0;
        if (!closest) return;

        const index = allDates.indexOf(closest);
        const xPos = x(closest);

        focusLine.attr("x1", xPos).attr("x2", xPos);

        focusDots
          .selectAll("circle")
          .data(sorted)
          .attr("cx", xPos)
          .attr("cy", (d) => y(d.values[index]?.minutes ?? 0));

        // Tooltip: date header + each series' minutes, sorted so the most
        // active categories appear first.
        const rows = sorted
          .map((s) => ({
            name: s.name,
            color: s.color,
            highlighted: s.highlighted,
            minutes: s.values[index]?.minutes ?? 0,
          }))
          .sort((a, b) => b.minutes - a.minutes);

        const dateLabel = d3.timeFormat("%b %d, %Y")(closest);

        tooltip.html(`
          <div class="font-medium text-primary mb-1">${dateLabel}</div>
          ${rows
            .map(
              (r) => `
                <div class="flex items-center justify-between gap-3 ${
                  hasHighlight && !r.highlighted ? "opacity-50" : ""
                }">
                  <span class="flex items-center gap-1.5 min-w-0">
                    <span class="w-2 h-2 rounded-full shrink-0" style="background-color: ${r.color}"></span>
                    <span class="truncate max-w-[140px]">${this._escape(r.name)}</span>
                  </span>
                  <span class="tabular-nums text-secondary">${this._formatMinutes(r.minutes)}</span>
                </div>
              `
            )
            .join("")}
        `);

        const ttWidth = tooltip.node().offsetWidth;
        const ttHeight = tooltip.node().offsetHeight;
        const pageX = event.clientX;
        const pageY = event.clientY;

        let left = pageX + 14;
        if (left + ttWidth > window.innerWidth - 8) {
          left = pageX - ttWidth - 14;
        }
        let top = pageY - ttHeight / 2;
        if (top < 8) top = 8;
        if (top + ttHeight > window.innerHeight - 8) {
          top = window.innerHeight - ttHeight - 8;
        }

        tooltip.style("left", `${left}px`).style("top", `${top}px`);
      });
  }

  _formatMinutes(minutes) {
    const m = Math.round(Number(minutes) || 0);
    if (m === 0) return "0m";
    const sign = m < 0 ? "-" : "";
    const abs = Math.abs(m);
    const h = Math.floor(abs / 60);
    const r = abs % 60;
    if (h > 0 && r > 0) return `${sign}${h}h ${r}m`;
    if (h > 0) return `${sign}${h}h`;
    return `${sign}${r}m`;
  }

  _escape(str) {
    return String(str ?? "").replace(/[&<>"']/g, (c) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;",
    })[c]);
  }
}
