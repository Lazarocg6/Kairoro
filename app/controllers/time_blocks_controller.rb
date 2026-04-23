class TimeBlocksController < ApplicationController
  before_action :set_time_block, only: %i[edit update destroy]

  def index
    @time_categories = Current.family.time_categories.alphabetically.includes(:parent)
    @recent_blocks = Current.family.time_blocks
      .for_user(Current.user)
      .chronological
      .includes(time_category: :parent)
      .limit(20)

    @time_block = Current.family.time_blocks.new(
      started_at: default_started_at,
      ended_at:   default_ended_at,
      user:       Current.user
    )

    today_range = Date.current.beginning_of_day..Date.current.end_of_day
    week_range  = Date.current.beginning_of_week..Date.current.end_of_week
    @today_minutes = Current.family.time_blocks.for_user(Current.user).between(today_range).to_a.sum(&:duration_minutes)
    @week_minutes  = Current.family.time_blocks.for_user(Current.user).between(week_range).to_a.sum(&:duration_minutes)

    @breadcrumbs = [ [ "Home", root_path ], [ t("time_blocks.index.title"), nil ] ]
  end

  def new
    @time_block = Current.family.time_blocks.new(
      started_at: default_started_at,
      ended_at:   default_ended_at,
      user:       Current.user
    )
    @time_categories = Current.family.time_categories.alphabetically.includes(:parent)
  end

  def create
    @time_block = Current.family.time_blocks.new(time_block_params.merge(user: Current.user))

    if @time_block.save
      redirect_target_url = request.referer || time_blocks_path
      respond_to do |format|
        format.html { redirect_back_or_to time_blocks_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, redirect_target_url) }
      end
    else
      @time_categories = Current.family.time_categories.alphabetically.includes(:parent)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @time_categories = Current.family.time_categories.alphabetically.includes(:parent)
  end

  def update
    if @time_block.update(time_block_params)
      redirect_target_url = request.referer || time_blocks_path
      respond_to do |format|
        format.html { redirect_back_or_to time_blocks_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, redirect_target_url) }
      end
    else
      @time_categories = Current.family.time_categories.alphabetically.includes(:parent)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @time_block.destroy
    redirect_back_or_to time_blocks_path, notice: t(".success")
  end

  def bulk_destroy
    ids = Array(params[:ids])
    Current.family.time_blocks.where(id: ids).destroy_all
    redirect_to time_blocks_path, notice: t(".success")
  end

  private
    def set_time_block
      @time_block = Current.family.time_blocks.find(params[:id])
    end

    def time_block_params
      params.require(:time_block).permit(:time_category_id, :started_at, :ended_at, :notes)
    end

    # Start a new block where the previous one ended so rapid/bulk entry
    # flows continuously. Falls back to 30 minutes ago if there's no prior block.
    def default_started_at
      @default_started_at ||= begin
        last_block = Current.family.time_blocks
          .for_user(Current.user)
          .order(ended_at: :desc)
          .first
        last_block&.ended_at || (Time.zone.now - 30.minutes)
      end
    end

    def default_ended_at
      default_started_at + 30.minutes
    end
end
