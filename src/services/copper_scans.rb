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

  # ---- AI label scan -------------------------------------------------------
  # Reads a photo of the coil's product label (e.g. JOBU/Daikin ACR tube) with
  # Claude vision and returns the tube specs so the UI can prefill the weight
  # form. Inert until ANTHROPIC_API_KEY is set — returns a clear 503 otherwise.
  LABEL_PROMPT = <<~TXT.freeze
    You are reading the product label printed on a coil of air-conditioner
    copper tube (brands like JOBU or Daikin; JIS H3300 / C1220 ACR seamless
    copper tubes). Extract the tube specifications.

    The outer diameter is usually an inch fraction with the millimetre value in
    brackets, e.g. 5/8" (15.88 MM). Wall thickness and coil length usually
    follow, e.g. "0.70 MM X 15 mtr", and the packed-coil weight is given in KGS.

    Report od_mm and wall_mm in millimetres, length_m in metres, and weight_kg
    in kilograms. Put every line of text you can read into raw_text. If the
    image is NOT a copper-tube label, set is_copper_tube to false. Use 0 for any
    number you cannot read and "" for any text you cannot read.
  TXT

  LABEL_SCHEMA = {
    type: 'object',
    additionalProperties: false,
    required: %w[is_copper_tube brand size_label od_mm wall_mm length_m weight_kg raw_text],
    properties: {
      is_copper_tube: { type: 'boolean' },
      brand:          { type: 'string' },
      size_label:     { type: 'string' },
      od_mm:          { type: 'number' },
      wall_mm:        { type: 'number' },
      length_m:       { type: 'number' },
      weight_kg:      { type: 'number' },
      raw_text:       { type: 'string' }
    }
  }.freeze

  def identify
    image = params[:image].to_s
    return_errors!('No image provided.', 400) if image.blank?
    parsed = vision_json!(image, LABEL_PROMPT, LABEL_SCHEMA)
    return_success(normalize_identification(parsed))
  end

  # ---- AI photo estimate ---------------------------------------------------
  # A quick, photo-only estimate of how much tube is left on a leftover coil.
  # Given the known full coil length, Claude judges the visual fullness of the
  # wound band and returns the fraction remaining + a confidence score. This is
  # an estimate (≈80–90%); weighing the coil is the exact method.
  ESTIMATE_SCHEMA = {
    type: 'object',
    additionalProperties: false,
    required: %w[is_coil fraction_remaining confidence notes],
    properties: {
      is_coil:            { type: 'boolean' },
      fraction_remaining: { type: 'number' }, # 0..1 of a full coil
      confidence:         { type: 'number' }, # 0..1
      notes:              { type: 'string' }
    }
  }.freeze

  def estimate
    image = params[:image].to_s
    return_errors!('No image provided.', 400) if image.blank?

    start = params[:start_length_m].to_f
    start = 15.0 if start <= 0
    product = params[:product].to_s.strip
    product = 'an AC copper tube coil' if product.empty?

    prompt = <<~TXT
      You are estimating how much refrigerant copper tube remains on a partly-used
      coil from a single photo. A brand-new full coil of this product (#{product})
      holds #{start} metres of tube.

      Judge how full the coil looks compared with a brand-new one — consider the
      radial thickness of the wound band (a near-full coil is a thick, dense
      ring; a nearly-empty one is a thin ring with a large empty centre), the
      number of visible turns, and the overall bulk. Estimate fraction_remaining
      as a value between 0 (empty) and 1 (a full coil).

      Set confidence between 0 and 1 based on how clearly you can judge the coil
      (angle, lighting, whether the whole coil is visible). If the image is not a
      coil of tube, set is_coil to false. Briefly explain your reasoning in notes.
    TXT

    parsed = vision_json!(image, prompt, ESTIMATE_SCHEMA)

    frac = parsed['fraction_remaining'].to_f.clamp(0.0, 1.0)
    conf = parsed['confidence'].to_f.clamp(0.0, 1.0)
    remaining = (frac * start).round(2)
    used = (start - remaining).round(2)

    return_success(
      is_coil:            parsed['is_coil'] != false,
      start_length_m:     start.round(2),
      fraction_remaining: frac.round(3),
      remaining_length_m: remaining,
      used_length_m:      used,
      confidence:         conf.round(2),
      notes:              parsed['notes'].to_s.strip
    )
  end

  # Shared Claude-vision JSON call. Halts the request with a clear error on any
  # misconfiguration/transport/parse failure; otherwise returns the parsed hash.
  def vision_json!(image, prompt, schema)
    require 'httpx'

    api_key = ENV['ANTHROPIC_API_KEY'].to_s
    if api_key.empty?
      return_errors!('AI features are not configured yet (missing ANTHROPIC_API_KEY).', 503)
    end

    media_type, data = parse_image(image)
    return_errors!('Unsupported image format.', 400) unless data

    body = {
      model: ENV.fetch('COPPER_VISION_MODEL', 'claude-haiku-4-5'),
      max_tokens: 1024,
      output_config: { format: { type: 'json_schema', schema: schema } },
      messages: [
        { role: 'user', content: [
          { type: 'image', source: { type: 'base64', media_type: media_type, data: data } },
          { type: 'text', text: prompt }
        ] }
      ]
    }

    res = HTTPX.with(timeout: { request_timeout: 30 }).post(
      'https://api.anthropic.com/v1/messages',
      headers: {
        'x-api-key' => api_key,
        'anthropic-version' => '2023-06-01',
        'content-type' => 'application/json'
      },
      json: body
    )

    if res.is_a?(HTTPX::ErrorResponse)
      App.logger.error("Anthropic vision network error: #{res.error&.message}")
      return_errors!('Could not reach the AI service. Try again or enter details manually.', 502)
    end
    unless res.status == 200
      App.logger.error("Anthropic vision failed: #{res.status} #{res.body}")
      return_errors!('The AI service could not process that image. Try again or enter details manually.', 502)
    end

    text = res.json.dig('content', 0, 'text')
    begin
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      return_errors!('Could not parse the AI response. Try again or enter details manually.', 502)
    end
  end

  # Split a data URL (data:image/jpeg;base64,XXXX) into [media_type, base64].
  # Falls back to treating a bare string as base64 JPEG.
  def parse_image(str)
    if str =~ %r{\Adata:(image/[a-zA-Z0-9.+-]+);base64,(.+)\z}m
      [$1, $2]
    else
      ['image/jpeg', str.presence]
    end
  end

  def normalize_identification(p)
    pos = ->(v) { f = v.to_f; f > 0 ? f.round(3) : nil }
    {
      is_copper_tube: p['is_copper_tube'] != false,
      brand:      p['brand'].to_s.strip.presence,
      size_label: p['size_label'].to_s.strip.presence,
      od_mm:      pos.call(p['od_mm']),
      wall_mm:    pos.call(p['wall_mm']),
      length_m:   pos.call(p['length_m']),
      weight_kg:  pos.call(p['weight_kg']),
      raw_text:   p['raw_text'].to_s.strip
    }
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
             :length_m, :method, :product, :start_length_m,
             :remaining_length_m, :leftover_weight_g, :kg_per_m,
             :gauge_system, :gauge_value, :diameter_mm,
             :weight_g, :image, :points, :notes, :status]
    }
  end
end
