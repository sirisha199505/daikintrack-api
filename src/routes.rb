
class App::Routes < Roda
  include App::Router::AllPlugins
  plugin :not_found do
    { status: 'error', data: 'Not Found' }
  end

  def do_crud(klass, r, only='CRUDL', opts = {})
    r.post { klass[r, opts].create } if only.include?('C')
    r.get(Integer) {|id| klass[r, opts.merge(id: id)].get} if only.include?('R')
    r.get { klass[r, opts].list } if only.include?('L')
    r.put(Integer) {|id| klass[r, opts.merge(id: id)].update } if only.include?('U')
    r.delete(Integer) {|id| klass[r, opts.merge(id: id)].delete } if only.include?('D')
  end

  route do |r|
    r.public

    r.root do
      File.read(File.join(App.root, 'public', 'index.html'))
    end

    r.on 'admin' do
      r.get do
        File.read(File.join(App.root, 'public', 'index.html'))
      end
    end

    r.on 'api' do
      r.response['Content-Type'] = 'application/json'
      
      # Public endpoints (no auth required)
      r.post('login') { Session[r].login }
      r.post('forgot-password') { Users[r].forgot_password }
      r.post('validate-password-token') { Users[r].validate_password_token }
      r.post('reset-password') { Users[r].reset_password }
      
      r.get 'version' do
        { status: 'success', version: 1 }
      end

      # Public, non-sensitive counts for the login/marketing screen.
      r.get 'stats' do
        { status: 'success', data: { warehouses: App::Models::Branch.where(active: true).count } }
      end

      # Authentication required for all routes below
      auth_required!

      begin
        # User profile routes
        r.on 'me' do
          r.get('info') { Users[r].info }
          r.put('update-password') { Users[r].update_password }
        end

        # ---- Catalog: readable by any authenticated user, ----
        # ---- create/edit allowed for admins and store managers       ----
        # ---- (managers scoped to their own branch); delete admin-only ----
        r.on 'products' do
          r.get('by-barcode') { Products[r].by_barcode }
          r.get(Integer) { |id| Products[r, id: id].get }
          r.post { product_write_required!; Products[r].create }
          r.put(Integer)    { |id| product_write_required!; Products[r, id: id].update }
          r.delete(Integer) { |id| admin_required!; Products[r, id: id].delete }
          r.get { Products[r].list }
        end

        # ---- Stock movements: any authenticated user may record ----
        r.on 'transactions' do
          r.get(Integer) { |id| Transactions[r, id: id].get }
          r.post { Transactions[r].create }
          r.get  { Transactions[r].list }
        end

        r.on 'branches' do
          r.get(Integer) { |id| Branches[r, id: id].get }
          r.post { admin_required!; Branches[r].create }
          r.put(Integer)    { |id| admin_required!; Branches[r, id: id].update }
          r.delete(Integer) { |id| admin_required!; Branches[r, id: id].delete }
          r.get { Branches[r].list }
        end

        r.on 'categories' do
          r.get(Integer) { |id| Categories[r, id: id].get }
          r.post { admin_required!; Categories[r].create }
          r.put(Integer)    { |id| admin_required!; Categories[r, id: id].update }
          r.delete(Integer) { |id| admin_required!; Categories[r, id: id].delete }
          r.get { Categories[r].list }
        end

        # ---- Admin-only: user management ----
        r.on 'users' do
          admin_required!
          do_crud(Users, r, 'CRUDL')
        end
      rescue => e
        App.logger.error("API Error: #{e.message}")
        App.logger.error(e.backtrace)
        { status: 'error', message: "An error occurred: #{e.message}" }
      end
    end

    # Fallback route
    r.get do
      File.read(File.join(App.root, 'public', 'index.html'))
    end
  end

  before do
    @time = Time.now
    App::Helpers::Before.run!(request)
  end

  after do |res|
    rtype = request.request_method
    App.logger.info("→ [#{Time.now - @time} seconds] - [#{rtype}]#{request.path}")
  end

  def auth_required!
    unless App.cu.valid?
      request.halt(401, {'Content-Type' => 'application/json'},{ status: 'Unauthorized!' }.to_json)
    end
  end

  def admin_required!
    unless App.cu.user_obj&.admin?
      request.halt(403, {'Content-Type' => 'application/json'},{ status: 'Forbidden!' }.to_json)
    end
  end

  # Product create/edit: admins (any branch) and store managers (own branch,
  # enforced in the service). Distributors and unknown roles are forbidden.
  def product_write_required!
    user = App.cu.user_obj
    unless user&.admin? || user&.store_manager?
      request.halt(403, {'Content-Type' => 'application/json'},{ status: 'Forbidden!' }.to_json)
    end
  end
end

App.require_blob('services/base.rb')
App.require_blob('services/*.rb')

App::Routes.send(:include, App::Services)