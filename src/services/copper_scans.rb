class App::Services::CopperScans < App::Services::Base
  def model; CopperScan; end

  # Shared filtered query for list + summary. Non-admins are scoped to their own
  # branch but may pass ?branch_id= to read another branch (matches products).
  def base_scope
    ds = model.order(Sequel.desc(:created_at))

    user = App.cu.user_obj
    if user && !user.admin? && user.branch_id
      ds = ds.where(branch_id: qs[:branch_id].presence || user.branch_id)
    elsif qs[:branch_id].present?
      ds = ds.where(branch_id: qs[:branch_id])
    end

    ds = ds.where(gauge_system: qs[:gauge_system]) if qs[:gauge_system].present?
    ds = ds.where(Sequel.lit('created_at >= ?', "#{qs[:from]} 00:00:00")) if qs[:from].present?
    ds = ds.where(Sequel.lit('created_at <= ?', "#{qs[:to]} 23:59:59")) if qs[:to].present?

    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where(
        Sequel.ilike(:notes, term) |
        Sequel.ilike(:actor, term) |
        Sequel.ilike(:gauge_value, term)
      )
    end

    ds
  end

  def list
    ds = base_scope
    count = ds.count
    items = ds.offset(offset).limit(limit).all.map(&:as_summary)
    return_success(items, total_pages: (count / page_size.to_f).ceil, total: count)
  end

  def get
    return_success(item.as_pos)
  end

  def create
    data = data_for(:save)
    data[:branch_id] = resolve_branch_id!(data[:branch_id])
    u = App.cu.user_obj
    data[:actor]      ||= u&.full_name
    data[:created_by] ||= u&.id
    obj = model.new(data)
    save(obj) { |o| return_success(o.as_pos) }
  end

  def delete
    res = item.delete
    res ? return_success(true) : return_errors!('Unable to delete')
  end

  # Aggregated analytics over the same filters as the list. Aggregated in Ruby
  # over a lean column projection (no base64 image) — datasets are modest.
  def summary
    rows = base_scope.select(:branch_id, :length_m, :weight_g, :created_at).all

    grams_to_kg = ->(rs) { (rs.sum { |r| r[:weight_g].to_f } / 1000.0).round(3) }
    sum_length  = ->(rs) { rs.sum { |r| r[:length_m].to_f }.round(2) }

    by_branch = rows.group_by { |r| r[:branch_id] }.map do |bid, rs|
      { branch_id: bid, branch_name: Branch[bid]&.name,
        scans: rs.size, length_m: sum_length.call(rs), weight_kg: grams_to_kg.call(rs) }
    end.sort_by { |b| -b[:weight_kg] }

    by_month = rows.group_by { |r| r[:created_at].strftime('%Y-%m') }.map do |m, rs|
      { month: m, scans: rs.size, length_m: sum_length.call(rs), weight_kg: grams_to_kg.call(rs) }
    end.sort_by { |x| x[:month] }

    return_success(
      total_scans:     rows.size,
      total_length_m:  sum_length.call(rows),
      total_weight_kg: grams_to_kg.call(rows),
      by_branch:       by_branch,
      by_month:        by_month
    )
  end

  # Admins record against any branch; managers against the branch they pass
  # (the one they've switched to) or their own when none is supplied.
  def resolve_branch_id!(requested)
    user = App.cu.user_obj
    return requested if user&.admin?
    if user && user.branch_id.blank? && requested.blank?
      return_errors!('You are not assigned to a branch.', 403)
    end
    requested.presence || user&.branch_id
  end

  def self.fields
    {
      save: [:branch_id, :reference_type, :reference_mm, :px_per_mm,
             :length_m, :gauge_system, :gauge_value, :diameter_mm,
             :weight_g, :image, :points, :notes, :status]
    }
  end
end
