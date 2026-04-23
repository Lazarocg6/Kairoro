class TimeCategoriesController < ApplicationController
  before_action :set_category, only: %i[edit update destroy]
  before_action :set_categories, only: %i[update edit]

  def index
    @time_categories = Current.family.time_categories.alphabetically
  end

  def new
    @time_category = Current.family.time_categories.new(color: TimeCategory::COLORS.sample, lucide_icon: "clock")
    set_categories
  end

  def create
    @time_category = Current.family.time_categories.new(category_params)

    if @time_category.save
      redirect_target_url = request.referer || time_categories_path
      respond_to do |format|
        format.html { redirect_back_or_to time_categories_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, redirect_target_url) }
      end
    else
      set_categories
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @time_category.update(category_params)
      redirect_target_url = request.referer || time_categories_path
      respond_to do |format|
        format.html { redirect_back_or_to time_categories_path, notice: t(".success") }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, redirect_target_url) }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @time_category.destroy
    redirect_back_or_to time_categories_path, notice: t(".success")
  end

  def destroy_all
    Current.family.time_categories.destroy_all
    redirect_back_or_to time_categories_path, notice: t(".success")
  end

  def bootstrap
    TimeCategory.bootstrap!(Current.family)
    redirect_back_or_to time_categories_path, notice: t(".success")
  end

  private
    def set_category
      @time_category = Current.family.time_categories.find(params[:id])
    end

    def set_categories
      @time_categories = unless @time_category&.parent?
        Current.family.time_categories.alphabetically.roots.where.not(id: @time_category&.id)
      else
        []
      end
    end

    def category_params
      params.require(:time_category).permit(:name, :color, :parent_id, :lucide_icon)
    end
end
