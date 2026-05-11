class HelpController < ApplicationController
  before_action :check_valid_login

  def index
    @user = User.find(session[:user_id])
  end
end
