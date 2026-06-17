class App::Services::Users < App::Services::Base
  def model; User; end

  RESET_TOKEN_EXPIRATION_TIME = 2 * 60 * 60 

  def list
    ds = model.where(active: true).order(Sequel.desc(:created_at))
    if qs[:search].present?
      search_term = "%#{qs[:search]}%"
      ds = ds.where(
        Sequel.ilike(:full_name, search_term) |
        Sequel.ilike(:username, search_term) |
        Sequel.ilike(:email, search_term)
      )
    end
    ds = ds.where(role: qs[:role]) if qs[:role].present?
    ds = ds.where(branch_id: qs[:branch_id]) if qs[:branch_id].present?
    count = ds.count
    return_success(ds.offset(offset).limit(limit).all.map(&:as_pos), total_pages: (count / page_size.to_f).ceil )
  end


  def get
    return_success(item.as_pos)
  end

  def create
    data = data_for(:save)
    obj = model.new(data.except(:password))
    obj.password = data[:password] if data[:password].present?
    save(obj) { |u| return_success(u.as_pos) }
  end

  def update(data = nil)
    data ||= data_for(:save)
    pwd = data.delete(:password)
    item.set_fields(data, data.keys)
    item.password = pwd if pwd.present?
    save(item) { |u| return_success(u.as_pos) }
  end

  def info
    return_success(
      App.cu.user_obj.as_json(only: [:email, :id, :full_name, :username, :role, :branch_id, :updated_at]).merge!(role_name: App.cu.user_obj.role_name)
    )
  end

  def update_password
    
    if App.cu.user_obj.password == params[:current_password]
      u = App.cu.user_obj
      u.password = params[:new_password]
      save(u) do |u|
        return_success("successfully updated password!!")
      end
    else
      return_errors!("Invalid password!!")
    end
  end

  def forgot_password
    email = params[:email]
    if email.present?
      user = App::Models::User.where(email: email).first
      if user
        user.send_password_reset_email('https://vhrr.net')
        return_success("Password reset email sent to #{user.email}")
      else
        return_errors("User not found with email: #{email}", 404)
      end
    else
      return_errors("User email is required!", 400)
    end
  end


  def validate_password_token
    token = params['token']
    
    if token.nil? || token.empty?
      return_errors!('Token is missing.', 400)
    else
      user = App::Models::User.where(reset_token: token).first
      if user && token_valid?(user)
        return_success('Token is valid.')
      else
        return_errors!('Invalid or expired token.')
      end
    end
  end

  def token_valid?(user)
    return false if user.reset_sent_at.nil?
  
    token_age = Time.now - user.reset_sent_at
    token_age < RESET_TOKEN_EXPIRATION_TIME
  end

  def reset_password
    token = params['token']
    new_password = params['password']

    if token.nil? || new_password.nil?
      return_errors!('Token and new password are required.', 400)
    else
      user = App::Models::User.where(reset_token: token).first
      if user && token_valid?(user)
        # Update the user's password and clear the reset token
        user.update(
          password: new_password,  # Use your password hashing logic here
          reset_token: nil,
          reset_sent_at: nil
        )
        return_success('Password has been reset.')
      else
        return_errors!('Invalid or expired token.', 400)
      end
    end
  end

  def self.fields
    {
      save: [:full_name, :username, :password, :email, :phone_number,
             :role, :branch_id, :status, :active]
    }
  end
end