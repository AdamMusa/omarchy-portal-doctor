# source: main.rb
# frozen_string_literal: true


# source: lib/backend.rb
# frozen_string_literal: true

class SuiteBackend
  SCORE_LABEL = "healthy routes"
  STATUSES = ["open", "tending", "complete"].freeze
  MAX_ITEMS = 128
  MAX_HISTORY = 256
  MAX_TEXT = 512
  MAX_STATE_BYTES = 262_144
  OUTPUT_LIMIT = 65_536

  Result = Struct.new(:stdout, :stderr, :exitstatus) do
    def success? = exitstatus.to_i.zero?
  end

  attr_reader :records

  def initialize(state_dir: File.expand_path("~/.local/state/omarchy-portal-doctor"), runner: nil)
    @state_dir = state_dir
    @state_path = File.join(state_dir, "state.json")
    @runner = runner
    @records = []
    @history = []
    @settings = {}
    @summary = "Starting"
    @score = 0
    @state_directory = create_directory(@state_dir)
    load_state
  end

  def snapshot
    {
      "items" => @records.first(MAX_ITEMS),
      "history" => @history.last(MAX_HISTORY),
      "summary" => clean(@summary, 100),
      "score" => @score.to_i,
      "updated_at" => Time.now.to_i
    }
  end

  def add(primary, secondary = "")
    title = clean(primary)
    detail = clean(secondary)
    return snapshot if title.empty?
    record = {
      "id" => "#{Time.now.to_i}-#{rand(1_000_000)}",
      "title" => title,
      "detail" => detail,
      "status" => STATUSES.first,
      "meta" => Time.now.strftime("%Y-%m-%d %H:%M")
    }
    after_add(record)
    @records.unshift(record)
    @records = @records.first(MAX_ITEMS)
    @score = @records.length
    @summary = "#{@records.length} #{SCORE_LABEL}"
    persist
    snapshot
  end

  def act(id)
    record = @records.find { |candidate| candidate["id"] == id.to_s }
    return snapshot unless record
    current = STATUSES.index(record["status"]) || 0
    record["status"] = STATUSES[(current + 1) % STATUSES.length]
    record["meta"] = "Updated #{Time.now.strftime("%Y-%m-%d %H:%M")}"
    persist
    snapshot
  end

  def remove(id)
    @records.reject! { |candidate| candidate["id"] == id.to_s }
    @score = @records.length
    @summary = @records.empty? ? "Ready" : "#{@records.length} #{SCORE_LABEL}"
    persist
    snapshot
  end

  def refresh
    scanned = scan_system
    @records = scanned if scanned.is_a?(Array)
    @records = @records.first(MAX_ITEMS)
    persist
    snapshot
  rescue StandardError => error
    @summary = "Needs attention"
    @records.unshift(item("Refresh issue", clean(error.message, 180), "inspect", "No system state was changed"))
    @records = @records.first(MAX_ITEMS)
    snapshot
  end

  private

  def after_add(record)
    record["status"] = STATUSES.first
    record
  end

  def scan_system
    output = command_text(["systemctl", "--user", "list-units", "--type=service", "--all", "--no-legend", "--no-pager"])
    rows = output.lines.filter_map do |line|
      fields = line.split
      next unless fields[0].to_s.include?("xdg-desktop-portal")
      active = fields[2].to_s == "active" && fields[3].to_s == "running"
      item(fields[0], fields.drop(4).join(" "), active ? "ready" : "inactive", "#{fields[2]} · #{fields[3]}")
    end
    desktop = clean(ENV.fetch("XDG_CURRENT_DESKTOP", "unknown"), 100)
    wayland = clean(ENV.fetch("WAYLAND_DISPLAY", "missing"), 100)
    rows.unshift(item("Wayland session", "#{desktop} · #{wayland}", wayland == "missing" ? "inspect" : "ready", "Portal routing context"))
    @score = rows.count { |record| record["status"] == "ready" }
    @summary = rows.length <= 1 ? "No portal backend" : "#{@score}/#{rows.length} routes ready"
    rows.first(MAX_ITEMS)
  end

  def item(title, detail, status = "observed", meta = "")
    {
      "id" => fnv1a("#{title}:#{detail}:#{status}"),
      "title" => clean(title), "detail" => clean(detail),
      "status" => clean(status, 80), "meta" => clean(meta, 240)
    }
  end

  def run(argv, timeout: 8)
    return @runner.call(argv, timeout: timeout) if @runner
    OmarchyUI::Command.run(argv, timeout: timeout, max_output_bytes: OUTPUT_LIMIT)
  rescue Errno::ENOENT, OmarchyUI::CommandTimeout, OmarchyUI::CommandOutputLimit
    nil
  end

  def command_text(argv, timeout: 8)
    result = run(argv, timeout: timeout)
    return "" unless result && result.success?
    clean(result.stdout.to_s, OUTPUT_LIMIT)
  end

  def parse_json(text)
    return nil if text.nil? || text.empty? || text.bytesize > OUTPUT_LIMIT
    JSON.parse(text)
  rescue JSON::ParserError
    nil
  end

  def clean(value, limit = MAX_TEXT)
    value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�").byteslice(0, limit).to_s
  rescue StandardError
    value.to_s.byteslice(0, limit).to_s
  end

  def safe_read(path, limit = MAX_STATE_BYTES, directory: nil, private_file: false)
    parent = directory || open_directory(File.dirname(path))
    close_parent = directory.nil?
    leaf = directory ? path.to_s : File.basename(path)
    return nil unless safe_leaf_name?(leaf)

    flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK | File::BINARY
    File.open(descriptor_path(parent, leaf), flags) do |file|
      file.close_on_exec = true
      metadata = descriptor_metadata(file)
      return nil unless safe_regular_file?(metadata, limit, private_file:)

      data = file.read(limit + 1)
      return nil if data && data.bytesize > limit
      data
    end
  rescue StandardError
    nil
  ensure
    parent.close if close_parent && parent && !parent.closed?
  end


  def relative_files(root)
    return [] unless File.directory?(root)
    result = []
    queue = [[root, ""]]
    until queue.empty? || result.length >= 2_000
      absolute, relative = queue.shift
      Dir.children(absolute).sort.first(512).each do |entry|
        next if entry == ".git" || entry == "node_modules" || entry == "vendor"
        child = File.join(absolute, entry)
        rel = relative.empty? ? entry : File.join(relative, entry)
        if File.directory?(child) && !File.symlink?(child)
          queue << [child, rel]
        elsif File.file?(child)
          result << rel
        end
      rescue SystemCallError
        next
      end
    end
    result
  end

  def executable?(name)
    return false if name.to_s.include?(File::SEPARATOR)
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
      path = File.join(directory, name.to_s)
      File.respond_to?(:executable?) ? File.executable?(path) : File.file?(path)
    end
  end

  def secure_equal?(left, right)
    return false unless left.bytesize == right.bytesize
    difference = 0
    left.bytes.zip(right.bytes) { |a, b| difference |= a ^ b }
    difference.zero?
  end

  def fnv1a(value)
    hash = 2_166_136_261
    value.to_s.each_byte { |byte| hash = ((hash ^ byte) * 16_777_619) & 0xffff_ffff }
    format("%08x", hash)
  end

  def percent(part, whole)
    return 0 if whole.to_i <= 0
    [[(part.to_f / whole.to_f * 100).round, 0].max, 100].min
  end

  def human_bytes(bytes)
    value = bytes.to_f
    units = %w[B KiB MiB GiB TiB]
    unit = units.shift
    while value >= 1024 && !units.empty?
      value /= 1024.0
      unit = units.shift
    end
    "#{value.round(value >= 10 ? 0 : 1)} #{unit}"
  end

  def human_duration(seconds)
    days = seconds.to_f / 86_400
    return "#{days.round} days" if days < 365
    "#{(days / 365).round(1)} years"
  end

  def short_path(path)
    home = File.expand_path("~")
    path.start_with?(home) ? path.sub(home, "~") : path
  end

  def descriptor_path(file, leaf = nil)
    base = "/proc/self/fd/#{file.fileno}"
    leaf ? File.join(base, leaf) : base
  end

  def current_uid
    return Process.uid if Process.respond_to?(:uid)
    return @current_uid if @current_uid

    result = OmarchyUI::Command.run(["/usr/bin/id", "-u"], timeout: 3, max_output_bytes: 128)
    raise "could not determine process owner" unless result.success?
    value = result.stdout.to_s.strip
    valid = !value.empty?
    value.each_byte { |byte| valid = false unless byte.between?(48, 57) }
    raise "invalid process owner" unless valid
    @current_uid = value.to_i
  end

  def safe_leaf_name?(name)
    !name.empty? && name != "." && name != ".." && !name.include?(File::SEPARATOR)
  end

  def descriptor_command(file, argv)
    inherited = file.close_on_exec?
    file.close_on_exec = false
    result = OmarchyUI::Command.run(argv, timeout: 3, max_output_bytes: 1_024)
    raise "descriptor command failed" unless result.success?
    result.stdout.to_s
  ensure
    file.close_on_exec = inherited if file && !file.closed?
  end

  def descriptor_metadata(file)
    if file.respond_to?(:stat)
      stat = file.stat
      return { mode: stat.mode, uid: stat.uid, links: stat.nlink, size: stat.size }
    end

    # Embedded mruby has no IO#stat; inspect the inherited descriptor through procfs.
    output = descriptor_command(
      file,
      ["/usr/bin/stat", "--dereference", "--format=%f:%u:%h:%s", descriptor_path(file)]
    ).strip
    mode, uid, links, size = output.split(":", 4)
    raise "invalid descriptor metadata" unless mode && uid && links && size
    { mode: mode.to_i(16), uid: uid.to_i, links: links.to_i, size: size.to_i }
  end

  def safe_directory?(metadata, private_directory: false)
    return false unless (metadata[:mode] & 0o170000) == 0o040000
    return false unless metadata[:uid] == current_uid || (!private_directory && metadata[:uid].zero?)
    return false if private_directory && (metadata[:mode] & 0o7777) != 0o700
    true
  end

  def directory_descriptor?(file)
    return file.stat.directory? if file.respond_to?(:stat)
    File.directory?(descriptor_path(file))
  end

  def safe_regular_file?(metadata, limit, private_file: false)
    return false unless (metadata[:mode] & 0o170000) == 0o100000
    return false unless metadata[:uid] == current_uid || (!private_file && metadata[:uid].zero?)
    return false unless metadata[:links] == 1
    return false if metadata[:size].negative? || metadata[:size] > limit
    return (metadata[:mode] & 0o7777) == 0o600 if private_file
    (metadata[:mode] & 0o7022).zero?
  end

  def open_directory(path, create: false, private_directory: false)
    expanded = File.expand_path(path)
    flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    current = File.open(File::SEPARATOR, flags)
    current.close_on_exec = true
    raise "unsafe directory" unless directory_descriptor?(current)

    expanded.split(File::SEPARATOR).reject(&:empty?).each do |part|
      raise "unsafe directory component" unless safe_leaf_name?(part)
      child_path = descriptor_path(current, part)
      if create
        begin
          Dir.mkdir(child_path, 0o700)
        rescue Errno::EEXIST
          nil
        end
      end
      child = File.open(child_path, flags)
      child.close_on_exec = true
      raise "unsafe directory" unless directory_descriptor?(child)
      current.close
      current = child
    end

    if private_directory
      File.chmod(0o700, descriptor_path(current))
      raise "unsafe state directory" unless safe_directory?(descriptor_metadata(current), private_directory: true)
    end
    current
  rescue StandardError
    current.close if current && !current.closed?
    raise
  end

  def create_directory(path)
    open_directory(path, create: true, private_directory: true)
  end

  def sync_descriptor(file, data_only: false)
    return file.fsync if file.respond_to?(:fsync)

    # Embedded mruby has no IO#fsync; sync the inherited file or directory descriptor.
    option = data_only ? "--data" : "--file-system"
    descriptor_command(file, ["/usr/bin/sync", option, descriptor_path(file)])
  end

  def load_state
    data = safe_read(File.basename(@state_path), MAX_STATE_BYTES, directory: @state_directory, private_file: true)
    return unless data
    parsed = data ? JSON.parse(data) : {}
    @records = Array(parsed["records"]).filter_map { |record| normalize_record(record) }.first(MAX_ITEMS)
    @history = Array(parsed["history"]).select { |entry| entry.is_a?(Hash) }.last(MAX_HISTORY)
    @settings = parsed["settings"].is_a?(Hash) ? parsed["settings"] : {}
    @score = @records.length
    @summary = @records.empty? ? "Ready" : "#{@records.length} #{SCORE_LABEL}"
  rescue JSON::ParserError, SystemCallError
    @records = []; @history = []; @settings = {}
  end

  def normalize_record(record)
    return nil unless record.is_a?(Hash)
    title = clean(record["title"])
    return nil if title.empty?
    {
      "id" => clean(record["id"], 80), "title" => title,
      "detail" => clean(record["detail"]), "status" => clean(record["status"], 80),
      "meta" => clean(record["meta"], 240), "evidence" => record["evidence"].is_a?(Hash) ? record["evidence"] : nil
    }.compact
  end

  def persist
    payload = JSON.generate("records" => @records.first(MAX_ITEMS), "history" => @history.last(MAX_HISTORY), "settings" => @settings)
    raise "state exceeds safety limit" if payload.bytesize > MAX_STATE_BYTES
    flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
    temporary_name = nil
    10.times do
      temporary_name = "state.json.tmp-#{Process.pid}-#{rand(1_000_000)}"
      begin
        File.open(descriptor_path(@state_directory, temporary_name), flags, 0o600) do |file|
          file.close_on_exec = true
          File.chmod(0o600, descriptor_path(file))
          metadata = descriptor_metadata(file)
          raise "unsafe private state file" unless safe_regular_file?(metadata, MAX_STATE_BYTES, private_file: true)
          file.write(payload)
          file.flush
          sync_descriptor(file, data_only: true)
        end
        break
      rescue Errno::EEXIST
        temporary_name = nil
      end
    end
    raise "could not allocate private state file" unless temporary_name
    File.rename(
      descriptor_path(@state_directory, temporary_name),
      descriptor_path(@state_directory, File.basename(@state_path))
    )
    sync_descriptor(@state_directory)
  ensure
    begin
      File.delete(descriptor_path(@state_directory, temporary_name)) if temporary_name
    rescue SystemCallError
      nil
    end
  end
end


backend = SuiteBackend.new

OmarchyUI.plugin do
  state :snapshot, backend.snapshot
  state :primary, ""
  state :secondary, ""
  state :compose, false
  state :page, 0
  state :selected_plugin, ""

  refresh = proc do
    state.snapshot = backend.refresh
  rescue StandardError
    state.snapshot = backend.snapshot
  end

  status_color = lambda do |status|
    value = status.to_s.downcase
    danger = false
    healthy = false
    %w[broken critical missing mismatch drift inactive slow tight risk invalid attention].each do |token|
      danger = true if value.include?(token)
    end
    %w[ready valid verified finished aligned unique internal familiar steady covered available detected normal active loaded].each do |token|
      healthy = true if value.include?(token)
    end
    if danger
      "#ff6b78"
    elsif healthy
      "#67d4c0"
    else
      "#efc66b"
    end
  end

  status_icon = lambda do |status|
    value = status.to_s.downcase
    danger = false
    healthy = false
    %w[broken critical missing mismatch drift inactive slow tight risk invalid attention].each do |token|
      danger = true if value.include?(token)
    end
    %w[ready valid verified finished aligned unique internal familiar steady covered available detected normal active loaded].each do |token|
      healthy = true if value.include?(token)
    end
    if danger
      :warning
    elsif healthy
      :circle_check
    else
      :circle_info
    end
  end

  first_number = lambda do |value|
    number = 0
    value.to_s.split.each do |token|
      candidate = token.to_i
      if candidate > 0
        number = candidate
        break
      end
    end
    number
  end

  bar_widget do
    row spacing: 6 do
      icon :circle_check, size: 14, color: "#67d4c0"
      text "PORTAL", style: :caption, color: "#67d4c0"
      text(style: :caption) { state.snapshot.fetch("summary") }
    end
    on_click { open_panel :portal_doctor }
  end

  panel :portal_doctor do
    scroll width: 660, height: 780 do
      dynamic id: :scene, spacing: 16 do
        entries = state.snapshot.fetch("items")
        ready = entries.count { |entry| entry.fetch("status", "") == "ready" }
        inactive = entries.count { |entry| entry.fetch("status", "") == "inactive" }

        column spacing: 2 do
          text "#{ready} routes are carrying desktop requests", style: :caption, width: 610
          row spacing: 9 do
            text "Portal", size: 30, bold: true
            icon :circle_check, size: 22, color: "#67d4c0"
            text "Doctor", size: 30, bold: true, width: 450
            action_button :refresh, tooltip: "Run portal checkup", foreground: "#67d4c0" do
              async(&refresh)
            end
          end
        end

        separator
        row spacing: 10 do
          column spacing: 2 do
            text "APPLICATION", style: :caption, color: "#829088"
            icon :window, size: 24, color: "#67d4c0"
          end
          text "━━━━━━●━━━━━", size: 17, color: "#67d4c0"
          column spacing: 2 do
            text "XDG PORTAL", style: :caption, color: "#829088"
            icon :link, size: 24, color: "#67d4c0"
          end
          text "━━━━━●━━━━━━", size: 17, color: "#67d4c0"
          column spacing: 2 do
            text "BACKEND", style: :caption, color: "#829088"
            icon :circle_check, size: 24, color: inactive.zero? ? "#d8ff73" : "#ff8b8b"
          end
        end
        text "━━━━━━━━━━━━━━╲╱━━━━━━━━━━━━━━╲╱━━━━━━━━━━━━━━━━━━━━", size: 14,
             color: inactive.zero? ? "#67d4c0" : "#ff8b8b"
        row spacing: 48 do
          column spacing: 0 do
            text ready.to_s.rjust(2, "0"), size: 44, bold: true, color: "#67d4c0"
            text "HEALTHY ROUTES", style: :caption
          end
          column spacing: 0 do
            text inactive.to_s.rjust(2, "0"), size: 30, bold: true,
                 color: inactive.zero? ? "#829088" : "#ff8b8b"
            text "NEEDS CARE", style: :caption
          end
        end
        text "SCREEN SHARE  ·  FILE DIALOG  ·  SANDBOX HANDOFF", style: :caption, color: "#829088"
        separator
        row spacing: 10 do
          text "ROUTE EXAM", size: 12, bold: true, color: "#67d4c0", width: 470
          text "USER SESSION", style: :caption, color: "#829088"
        end

        if entries.empty?
          column spacing: 8 do
            icon :warning, size: 30, color: "#ff8b8b"
            text "No portal pulse detected", size: 21, bold: true
            text "No desktop portal services were visible in the user session.",
                 style: :caption, wrap: true, width: 560
          end
        else
          entries.each_with_index do |entry, index|
            route_color = entry.fetch("status", "") == "ready" ? "#67d4c0" : "#ff8b8b"
            column spacing: 4 do
              row spacing: 10 do
                text (index + 1).to_s.rjust(2, "0"), style: :caption, color: route_color, width: 24
                icon status_icon.call(entry.fetch("status", "")), size: 14, color: route_color
                column spacing: 1 do
                  text entry.fetch("title"), width: 420, size: 15, bold: true, wrap: true
                  text entry.fetch("detail", ""), style: :caption, width: 420, wrap: true
                end
                text entry.fetch("status", "").upcase, style: :caption, color: route_color, width: 100
              end
              text "    ●━━━━━━━━━━━━━━╲╱━━━━━━━━━━━━━━━━━━━━━━━━●", style: :caption, color: route_color
              text "    #{entry.fetch("meta", "")}", style: :caption, color: "#829088", width: 560, wrap: true
            end
            separator unless index == entries.length - 1
          end
        end
      end
    end
  end

  after(0.08, &refresh)
  every(30, &refresh)
end
