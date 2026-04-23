class TimeCategory::DeletionsController < ApplicationController
  before_action :set_category

  def new
    @time_categories = Current.family.time_categories.alphabetically.where.not(id: @time_category.id)
  end

  def create
    replacement = Current.family.time_categories.find_by(id: params[:replacement_time_category_id])
    @time_category.replace_and_destroy!(replacement)

    redirect_to time_categories_path, notice: t(".success")
  end

  private
    def set_category
      @time_category = Current.family.time_categories.find(params[:time_category_id])
    end
end
