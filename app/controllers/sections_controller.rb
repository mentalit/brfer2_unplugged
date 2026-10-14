class SectionsController < ApplicationController
  before_action :set_section, only: %i[ show edit update destroy ]
  before_action :get_aisle, only: %i[ new create index]

  # GET /sections or /sections.json
  def index
    @sections = @aisle.sections
  end

  # GET /sections/1 or /sections/1.json
  def show
  end

  # GET /sections/new
  def new
    @section = @aisle.sections.build
  end

  # GET /sections/1/edit
  def edit
  end

  # POST /sections or /sections.json
  def create
    @section = @aisle.sections.build(section_params)

    respond_to do |format|
      if @section.save
        format.html { redirect_to @section, notice: "Section was successfully created." }
        format.json { render :show, status: :created, location: @section }
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @section.errors, status: :unprocessable_content }
      end
    end
  end

  # PATCH/PUT /sections/1 or /sections/1.json
  def update
    respond_to do |format|
      if @section.update(section_params)
        format.html { redirect_to @section, notice: "Section was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @section }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @section.errors, status: :unprocessable_content }
      end
    end
  end

  # DELETE /sections/1 or /sections/1.json
  def destroy
    @section.destroy!

    respond_to do |format|
      format.html { redirect_to sections_path, notice: "Section was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_section
      @section = Section.find(params.expect(:id))
    end

    def get_aisle
      @aisle = Aisle.find(params[:aisle_id])
    end

    # Only allow a list of trusted parameters through.
    def section_params
      params.expect(section: [ :Sec_num, :sec_width, :sec_length, :sec_depth, :sec_height, :aisle_id ])
    end
end
